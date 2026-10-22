import AppKit
import AVFoundation
import CoreBluetooth
import IOBluetooth
import SwiftUI

/// Announces Bluetooth audio devices (AirPods, Beats, headphones, speakers) as they
/// connect/disconnect, keeps `DevicesState` current and warns when their battery runs low.
@MainActor
final class BluetoothMonitor: NSObject {
    static let shared = BluetoothMonitor()

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    /// Lowest warning level already announced per device.
    private var warned: [String: Double] = [:]
    /// Apple product IDs of paired devices, by `key(_:)` address (from system_profiler).
    private var productIDs: [String: Int] = [:]
    private var profiling = false
    private var startedAt = Date.distantFuture
    private var timer: Timer?
    private var ticks = 0
    /// Colours read from AirPods Max advertisements, by device id (kept for reconnections).
    private var tints: [String: NSColor] = [:]
    private var central: CBCentralManager?
    /// The AirPods Max a colour scan listens for, and the colour codes heard per peripheral.
    private var scanTarget: ConnectedDevice?
    private var heardColors: [UUID: UInt8] = [:]
    private var scanTimer: Timer?

    func start() {
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            track(d, announce: false)
        }
        // Every paired device's model, so renamed AirPods are recognised as they connect.
        fetchProfiler()
        // Battery levels drift: re-read them every 10 s while something is connected, so a
        // device crossing the warning level is announced within seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { BluetoothMonitor.shared.refreshBatteries() }
        }
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Registration replays devices that were already connected: stay quiet at launch.
        track(device, announce: Date().timeIntervalSince(startedAt) > 2)
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let id = Self.id(of: device)
        disconnectNotes.removeValue(forKey: id)?.unregister()
        guard let gone = DevicesState.shared.devices.first(where: { $0.id == id }) else { return }
        disconnect(gone)
    }

    private func track(_ d: IOBluetoothDevice, announce: Bool) {
        let id = Self.id(of: d)
        let productID = productIDs[Self.key(id)]
        let kind = Self.classify(d, productID: productID)
        guard kind.audio || SystemPreferences.shared.bluetoothAllDevices else { return }
        if disconnectNotes[id] == nil {
            disconnectNotes[id] = d.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        }
        let levels = Self.batteries(of: d)
        let device = ConnectedDevice(
            id: id, name: d.name ?? "Bluetooth device", symbol: kind.symbol, battery: levels.main, caseBattery: levels.case, tint: tints[id]
        )
        connect(device, earbuds: kind.earbuds, announce: announce)
        lookUpColor(device, productID: productID)
        // Paired after launch, or levels IOBluetooth won't give: ask system_profiler.
        if productID == nil || levels.main == nil { fetchProfiler() }
    }

    /// Shared by real events and `system.bluetooth` debug simulations.
    func connect(_ device: ConnectedDevice, earbuds: Bool, announce: Bool) {
        var list = DevicesState.shared.devices.filter { $0.id != device.id }
        list.append(device)
        DevicesState.shared.devices = list
        if announce, SystemPreferences.shared.bluetoothNotification {
            Island.shared.post(BluetoothItems.connected(device, earbuds: earbuds))
        }
        checkBattery(device, announce: announce)
    }

    func disconnect(_ device: ConnectedDevice) {
        DevicesState.shared.devices.removeAll { $0.id == device.id }
        warned.removeValue(forKey: device.id)
        if SystemPreferences.shared.bluetoothNotification { Island.shared.post(BluetoothItems.disconnected(device)) }
    }

    /// Devices warn at their own level (Connectivity › Warn at), then again at 10%.
    private func checkBattery(_ device: ConnectedDevice, announce: Bool) {
        let prefs = SystemPreferences.shared
        guard let level = device.battery, prefs.deviceLowBattery else { return }
        if level > prefs.deviceLowBatteryThreshold { warned[device.id] = 1; return }
        guard let t = PowerMonitor.warning(level: level, threshold: prefs.deviceLowBatteryThreshold, warned: warned[device.id] ?? 1) else { return }
        warned[device.id] = t
        guard announce else { return }
        // Connection notification first, the warning right after it.
        let delay = Island.shared.transient?.id == "system.bluetooth" ? Preferences.shared.notificationDuration : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Island.shared.post(BluetoothItems.lowBattery(device), duration: 5)
            if prefs.deviceLowBatterySound { Sounds.lowBattery() }
        }
    }

    private func refreshBatteries() {
        guard !DevicesState.shared.devices.isEmpty else { return }
        ticks += 1
        var unreported = false
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            let id = Self.id(of: d)
            guard var device = DevicesState.shared.devices.first(where: { $0.id == id }) else { continue }
            let levels = Self.batteries(of: d)
            guard let main = levels.main else {
                if device.battery != nil { unreported = true }
                continue
            }
            device.battery = main
            device.caseBattery = levels.case
            update(device)
        }
        // Levels only system_profiler reports: refreshed once a minute (a 0.2 s run).
        if unreported, ticks % 6 == 0 { fetchProfiler() }
    }

    /// A fresh reading for a tracked device (also `system.devicebattery`).
    func update(_ device: ConnectedDevice) {
        guard let i = DevicesState.shared.devices.firstIndex(where: { $0.id == device.id }),
              DevicesState.shared.devices[i] != device else { return }
        DevicesState.shared.devices[i] = device
        checkBattery(device, announce: true)
    }

    // MARK: - Device facts

    nonisolated private static func id(of d: IOBluetoothDevice) -> String { d.addressString ?? d.name ?? "device" }

    /// IOBluetooth says "aa-bb-…", system_profiler "AA:BB:…".
    nonisolated static func key(_ address: String) -> String { address.uppercased().replacingOccurrences(of: "-", with: ":") }

    /// SF Symbol plus whether it is an audio device and in-ear (gets the earbuds clip): by
    /// Apple product ID first (renamed AirPods too), then by name, then by Bluetooth class.
    nonisolated static func classify(_ d: IOBluetoothDevice, productID: Int?) -> (symbol: String, audio: Bool, earbuds: Bool) {
        if let model = productID.flatMap(model) { return model }
        let fromName = classify(name: d.name ?? "")
        if fromName.audio { return fromName }
        switch (d.deviceClassMajor, d.deviceClassMinor) {
        case (0x04, 0x05), (0x04, 0x0A), (0x04, 0x07): return ("hifispeaker.fill", true, false)
        case (0x04, 0x06): return ("headphones", true, false)
        case (0x04, _): return ("headphones", true, false)
        case (0x05, let minor) where minor & 0x10 != 0: return ("keyboard", false, false)
        case (0x05, let minor) where minor & 0x20 != 0: return ("computermouse", false, false)
        default: return ("dot.radiowaves.left.and.right", false, false)
        }
    }

    /// Also what the HUD falls back to for an output device's name.
    nonisolated static func classify(name raw: String) -> (symbol: String, audio: Bool, earbuds: Bool) {
        let name = raw.lowercased()
        if name.contains("airpods max") { return (DeviceSymbol.first(["airpods.max", "airpodsmax"]), true, false) }
        if name.contains("airpods pro") { return (DeviceSymbol.first(["airpods.pro", "airpodspro"]), true, true) }
        if name.contains("airpods") { return ("airpods", true, true) }
        if name.contains("beats") {
            let overEar = name.contains("studio") || name.contains("solo")
            return (overEar ? "beats.headphones" : "beats.earphones", true, !overEar)
        }
        if name.contains("homepod") { return (name.contains("mini") ? "homepod.mini.fill" : "homepod.fill", true, false) }
        if name.contains("earpods") { return ("earpods", true, true) }
        if name.contains("buds") { return ("earbuds", true, true) }
        return ("headphones", false, false)
    }

    nonisolated static func model(_ productID: Int) -> (symbol: String, audio: Bool, earbuds: Bool)? {
        models[productID].map { (DeviceSymbol.first($0.symbols), true, $0.earbuds) }
    }

    /// Apple Bluetooth product IDs (vendor 0x004C): SF Symbols to try, newest first, and
    /// whether the model sits in the ear. IDs from AppleDB (github.com/littlebyteorg/appledb,
    /// deviceFiles/AirPods and deviceFiles/Beats, "Device1,<decimal ID>"); they match
    /// system_profiler's device_productID and the <decimal ID>.data files in macOS's
    /// HeadphoneManager.framework.
    nonisolated static let models: [Int: (symbols: [String], earbuds: Bool)] = [
        0x2002: (["airpods"], true),  // AirPods
        0x200F: (["airpods"], true),  // AirPods (2nd generation)
        0x2013: (["airpods.gen3", "airpods"], true),  // AirPods (3rd generation)
        0x2019: (["airpods.gen4", "airpods.gen3", "airpods"], true),  // AirPods 4
        0x201B: (["airpods.gen4", "airpods.gen3", "airpods"], true),  // AirPods 4 with ANC
        0x2030: (["airpods.gen4", "airpods.gen3", "airpods"], true),  // AirPods 5 (wireless case)
        0x2036: (["airpods.gen4", "airpods.gen3", "airpods"], true),  // AirPods 5
        0x200E: (["airpods.pro", "airpodspro"], true),  // AirPods Pro
        0x2014: (["airpods.pro", "airpodspro"], true),  // AirPods Pro 2 (Lightning)
        0x2024: (["airpods.pro", "airpodspro"], true),  // AirPods Pro 2 (USB-C)
        0x2027: (["airpods.pro", "airpodspro"], true),  // AirPods Pro 3
        0x2028: (["airpods.pro", "airpodspro"], true),  // AirPods Pro 3
        0x200A: (["airpods.max", "airpodsmax"], false),  // AirPods Max (Lightning)
        0x201F: (["airpods.max", "airpodsmax"], false),  // AirPods Max (USB-C)
        0x202D: (["airpods.max", "airpodsmax"], false),  // AirPods Max 2
        0x2003: (["beats.powerbeats3", "beats.earphones"], true),  // Powerbeats3
        0x2005: (["beats.earphones"], true),  // BeatsX
        0x2006: (["beats.headphones"], false),  // Beats Solo3
        0x2007: (["beats.headphones"], false),  // Beats Studio3
        0x2009: (["beats.headphones"], false),  // Beats Studio3
        0x200B: (["beats.powerbeats.pro", "beats.earphones"], true),  // Powerbeats Pro
        0x200C: (["beats.headphones"], false),  // Beats Solo Pro
        0x200D: (["beats.powerbeats", "beats.earphones"], true),  // Powerbeats (4th generation)
        0x2010: (["beats.earphones"], true),  // Beats Flex
        0x2011: (["beats.studiobuds", "beats.earphones"], true),  // Beats Studio Buds
        0x2012: (["beats.fitpro", "beats.earphones"], true),  // Beats Fit Pro
        0x2016: (["beats.studiobuds", "beats.earphones"], true),  // Beats Studio Buds +
        0x2017: (["beats.headphones"], false),  // Beats Studio Pro
        0x201A: (["beats.pill", "hifispeaker.fill"], false),  // Beats Pill
        0x201D: (["beats.powerbeats.pro.2", "beats.powerbeats.pro", "beats.earphones"], true),  // Powerbeats Pro 2
        0x2025: (["beats.headphones"], false),  // Beats Solo 4
        0x2026: (["beats.solobuds", "beats.earphones"], true),  // Beats Solo Buds
        0x202F: (["beats.fitpro", "beats.earphones"], true),  // Powerbeats Fit
    ]

    /// The one model whose colour codes a source names: AirPods Max (Lightning).
    nonisolated static let colorModel = 0x200A

    /// Its colour codes: the label an iPhone's pairing card showed for each, from the
    /// `colors_airpods_max` table of Flipper Zero's BLE spam app (Willy-JL;
    /// github.com/Next-Flip/Momentum-Apps, ble_spam/protocols/continuity.c, same table in
    /// simondankelmann/Bluetooth-LE-Spam), then the gen-1 finish we pair it with (five codes,
    /// five finishes; the pairing is ours). 0x0F and 0x03 were also captured from real AirPods
    /// Max (CAPod's AirPodsMaxTest, github.com/d4rken-org/capod; OpenPods issue #124). Codes
    /// are per model (the USB-C AirPods Max sent 0x12, which no source names), so every other
    /// model stays untinted. Tints: the finishes, light enough to read on black.
    nonisolated static let maxColors: [UInt8: (label: String, finish: String, tint: NSColor)] = [
        0x00: ("White", "Silver", NSColor(srgbRed: 0.88, green: 0.89, blue: 0.91, alpha: 1)),
        0x02: ("Red", "Pink", NSColor(srgbRed: 1, green: 0.62, blue: 0.62, alpha: 1)),
        0x03: ("Blue", "Sky Blue", NSColor(srgbRed: 0.6, green: 0.78, blue: 0.96, alpha: 1)),
        0x0F: ("Black", "Space Gray", NSColor(srgbRed: 0.66, green: 0.67, blue: 0.71, alpha: 1)),
        0x11: ("Light Green", "Green", NSColor(srgbRed: 0.74, green: 0.85, blue: 0.71, alpha: 1)),
    ]

    /// A colour code as a tint; nil unless a source names that code for that model.
    nonisolated static func tint(model: Int, color: UInt8) -> NSColor? {
        model == colorModel ? maxColors[color]?.tint : nil
    }

    /// `color=` of the `system.bluetooth` simulation: a code (`0x02`), label (`red`) or finish (`pink`).
    nonisolated static func maxTint(_ arg: String) -> NSColor? {
        func squash(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
        let code = UInt8(squash(arg).replacingOccurrences(of: "0x", with: ""), radix: 16)
        return maxColors.first { $0.key == code || [$0.value.label, $0.value.finish].map(squash).contains(squash(arg)) }?.value.tint
    }

    /// Best effort: Apple accessories expose battery percentages on IOBluetoothDevice (private keys).
    nonisolated static func batteries(of d: IOBluetoothDevice) -> (main: Double?, case: Double?) {
        func read(_ key: String) -> Double? {
            guard d.responds(to: Selector(key)), let n = d.value(forKey: key) as? NSNumber, n.intValue > 0 else { return nil }
            return n.doubleValue / 100
        }
        let single = read("batteryPercentSingle") ?? read("batteryPercentCombined")
        let buds = [read("batteryPercentLeft"), read("batteryPercentRight")].compactMap { $0 }
        return (single ?? buds.min(), read("batteryPercentCase"))
    }

    /// system_profiler knows every paired device's product ID, and the battery levels some
    /// accessories don't give IOBluetooth: one run at a time, off the main thread.
    private func fetchProfiler() {
        guard !profiling else { return }
        profiling = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var data = Data()
            if (try? p.run()) != nil {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            }
            let entries = Self.profilerDevices(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { BluetoothMonitor.shared.received(entries) }
            }
        }
    }

    private func received(_ entries: [String: ProfilerEntry]) {
        profiling = false
        let known = productIDs
        for (key, entry) in entries { if let id = entry.productID { productIDs[key] = id } }
        for var device in DevicesState.shared.devices {
            guard let entry = entries[Self.key(device.id)] else { continue }
            if let model = entry.productID.flatMap(Self.model) { device.symbol = model.symbol }
            if let main = entry.main {
                device.battery = main
                device.caseBattery = entry.case
            }
            update(device)
            // Its model only just became known (connected at launch, or paired since).
            if known[Self.key(device.id)] == nil { lookUpColor(device, productID: entry.productID) }
        }
    }

    typealias ProfilerEntry = (productID: Int?, main: Double?, case: Double?)

    /// Parses `system_profiler SPBluetoothDataType -json`, connected and paired devices, by
    /// `key(_:)` address: the product ID (Apple's vendor ID only) and battery levels.
    nonisolated static func profilerDevices(_ data: Data) -> [String: ProfilerEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: ProfilerEntry] = [:]
        for section in sections {
            for list in ["device_connected", "device_not_connected"] {
                for entry in section[list] as? [[String: Any]] ?? [] {
                    for case let info as [String: Any] in entry.values {
                        guard let address = info["device_address"] as? String else { continue }
                        func hex(_ k: String) -> Int? { (info[k] as? String).flatMap { Int($0.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) } }
                        func pct(_ k: String) -> Double? { (info[k] as? String).flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }.map { $0 / 100 } }
                        let main = pct("device_batteryLevelMain") ?? [pct("device_batteryLevelLeft"), pct("device_batteryLevelRight")].compactMap { $0 }.min()
                        result[key(address)] = (hex("device_vendorID") == 0x004C ? hex("device_productID") : nil, main, pct("device_batteryLevelCase"))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Colour

    /// AirPods Max tell their colour only in their BLE advertisement: listen ~10 s after one
    /// connects, one at a time. Only with Bluetooth access already granted: a CBCentralManager
    /// created while access is undecided would show the permission prompt.
    private func lookUpColor(_ device: ConnectedDevice, productID: Int?) {
        guard productID == Self.colorModel, tints[device.id] == nil, scanTarget == nil,
              CBManager.authorization == .allowedAlways else { return }
        scanTarget = device
        heardColors = [:]
        if let central {
            scan(central)
        } else {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            MainActor.assumeIsolated { BluetoothMonitor.shared.endScan() }
        }
    }

    private func scan(_ central: CBCentralManager) {
        guard scanTarget != nil, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil)
    }

    private func heard(_ ad: ProximityPairing, from peripheral: UUID, named name: String?) {
        guard let target = scanTarget, ad.model == Self.colorModel else { return }
        heardColors[peripheral] = ad.color
        // A peripheral carrying the connected device's name is taken to be it (AirBattery
        // reads AirPods adverts by peripheral name too).
        if name == target.name { endScan(color: ad.color) }
    }

    /// Keeps the named device's colour, else the one every AirPods Max heard agreed on
    /// (another one nearby in a different colour leaves the glyph untinted).
    private func endScan(color: UInt8? = nil) {
        scanTimer?.invalidate()
        central?.stopScan()
        let target = scanTarget, codes = Set(heardColors.values)
        scanTarget = nil
        heardColors = [:]
        guard let target, let code = color ?? (codes.count == 1 ? codes.first : nil),
              let tint = Self.tint(model: Self.colorModel, color: code) else { return }
        tints[target.id] = tint
        guard var device = DevicesState.shared.devices.first(where: { $0.id == target.id }) else { return }
        device.tint = tint
        update(device)
    }
}

extension BluetoothMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { scan(central) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, let ad = ProximityPairing(data) else { return }
        let id = peripheral.identifier, name = peripheral.name
        MainActor.assumeIsolated { heard(ad, from: id, named: name) }
    }
}

/// Apple's "proximity pairing" BLE advertisement, broadcast by AirPods and Beats in use.
/// Manufacturer data as CoreBluetooth hands it over, laid out per furiousMAC/continuity
/// (github.com/furiousMAC/continuity, messages/proximity_pairing.md and its Wireshark
/// dissector), AirBattery (github.com/lihaoyun6/AirBattery, BatteryInfo/BLEBattery.swift)
/// and OpenPods (github.com/adolfintel/OpenPods, pods/PodsStatus.java):
///
///     0-1  4C 00  Apple's company ID          7   status
///     2    07     proximity pairing           8   pod batteries, a nibble each
///     3    19     25 bytes follow             9   charging flags | case battery (low nibble)
///     4    01     a paired device's status    10  lid open counter
///     5-6  0A 20  model, little-endian:       11  colour
///                 product ID 0x200A           12-28  not read (13-28 encrypted)
///
/// Batteries are tens of percent, 0xF when unknown; with status bit 5 clear the high nibble
/// is the left pod (OpenPods' isFlipped). Single-cell headphones such as the AirPods Max put
/// their level in the low nibble, so it lands in `left` or `right` and the other reads 0.
struct ProximityPairing {
    var model: Int
    var color: UInt8
    var left: Double?
    var right: Double?
    var `case`: Double?

    init?(_ data: Data) {
        let b = [UInt8](data)
        // Pods also send type-07 frames with other prefixes in another format (CAPod #603).
        guard b.count >= 29, b.starts(with: [0x4C, 0x00, 0x07, 0x19, 0x01]) else { return nil }
        func level(_ nibble: UInt8) -> Double? { nibble == 0xF ? nil : min(1, Double(nibble) / 10) }
        let flipped = b[7] & 0x20 == 0
        model = Int(b[5]) | Int(b[6]) << 8
        color = b[11]
        left = level(flipped ? b[8] >> 4 : b[8] & 0xF)
        right = level(flipped ? b[8] & 0xF : b[8] >> 4)
        self.case = level(b[9] & 0xF)
    }

    /// Canned advertisements from the sources; runs with every gallery render.
    static func selfCheck() {
        func ad(_ hex: String) -> ProximityPairing? { ProximityPairing(Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })) }
        // Real AirPods Max (Lightning) captures, CAPod's AirPodsMaxTest ("some dude at the gym"; OpenPods #124).
        let blue = ad("4C 00 07 19 01 0A 20 23 07 80 03 03 65 1F 28 32 D0 D9 71 43 00 9A 40 E7 6B EA 6C 2C FB")
        precondition(blue?.model == 0x200A && blue?.color == 0x03 && blue?.left == 0.7 && blue?.right == 0, "AirPods Max, level in the low nibble")
        precondition(blue.flatMap { BluetoothMonitor.tint(model: $0.model, color: $0.color) } == BluetoothMonitor.maxColors[0x03]?.tint, "AirPods Max colour tints")
        let gray = ad("4C 00 07 19 01 0A 20 62 04 80 01 0F 40 0D 70 50 16 F2 40 83 16 BF 10 16 34 9B 74 84 E8")
        precondition(gray?.color == 0x0F && gray?.left == 0.4 && BluetoothMonitor.tint(model: 0x200A, color: 0x0F) != nil, "AirPods Max 0x0F")
        // AirPods Pro (CAPod's AirPodsProTest): 0x00 is a colour only for the AirPods Max.
        let pro = ad("4C 00 07 19 01 0E 20 54 AA B5 31 00 00 E0 0C A7 8A 60 4B D3 7D F4 60 4F 2C 73 E9 A7 F4")
        precondition(pro?.model == 0x200E && pro?.color == 0 && pro?.left == 1 && pro?.right == 1 && pro?.case == 0.5, "AirPods Pro")
        precondition(pro.flatMap { BluetoothMonitor.tint(model: $0.model, color: $0.color) } == nil, "codes are per model: no tint")
        let flipped = ad("4C 00 07 19 01 0E 20 00 F3 8F 02 00 04 79 C6 3F F9 C3 15 D9 11 A1 3C B1 58 66 B9 8B 67")
        precondition(flipped?.left == nil && flipped?.right == 0.3 && flipped?.case == nil, "flipped pods; 0xF is unknown")
        // Cut short, and AppleJuice's spoofed new-device pop-up (prefix 07).
        precondition(ad("4C 00 07 19 01 0A 20 23 07 80 03 03") == nil, "too short")
        precondition(ad("4C 00 07 19 07 0A 20 75 AA 30 01 00 00 45 12 12 12 00 00 00 00 00 00 00 00 00 00 00 00") == nil, "other prefix")
        precondition(BluetoothMonitor.maxTint("pink") == BluetoothMonitor.maxTint("red") && BluetoothMonitor.maxTint("0x02") == BluetoothMonitor.maxColors[0x02]?.tint
            && BluetoothMonitor.maxTint("Sky Blue") != nil && BluetoothMonitor.maxTint("purple") == nil, "debug colour names")
    }
}

@MainActor
enum BluetoothItems {
    /// In-ear devices loop the earbuds clip, unless Connectivity › Device image asks for symbols.
    static func connected(_ device: ConnectedDevice, earbuds: Bool) -> IslandItem {
        IslandItem(id: "system.bluetooth", kind: .notification) {
            if earbuds, SystemPreferences.shared.deviceImage == .model, EarbudsVideo.url != nil, !SystemModule.renderingGallery {
                EarbudsVideo().frame(width: 32, height: 32).padding(.leading, 6).padding(.bottom, 2)
            } else {
                DeviceGlyph(device: device).padding(.leading, 11)
            }
        } trailing: {
            Group {
                if let level = device.battery {
                    BatteryRing(level: level)
                } else {
                    Image(systemName: "checkmark.circle.fill").islandSymbol(17).foregroundStyle(Palette.green)
                }
            }
            .padding(.trailing, 10)
        }
        .peek(onHover: true) { PeekLabel(caption(device)) }
    }

    static func disconnected(_ device: ConnectedDevice) -> IslandItem {
        IslandItem(id: "system.bluetooth", kind: .notification) {
            Image(systemName: DeviceSymbol.resolve(device.symbol)).islandSymbol(17).foregroundStyle(Palette.muted).padding(.leading, 11)
        } trailing: {
            WingText("Off", color: Palette.muted)
        }
        .peek(onHover: true) { PeekLabel(device.name) }
    }

    static func lowBattery(_ device: ConnectedDevice) -> IslandItem {
        IslandItem(id: "system.deviceBattery", kind: .notification) {
            Image(systemName: DeviceSymbol.resolve(device.symbol)).islandSymbol(17).foregroundStyle(Palette.ink).padding(.leading, 11)
        } trailing: {
            BatteryRing(level: device.battery ?? 0, color: Palette.red).padding(.trailing, 10)
        }
        .peek(always: true) { PeekLabel("\(device.name) · \(PowerItems.percent(device.battery ?? 0))") }
    }

    /// "AirPods Pro · 76%" (the case level lives in DevicesState for the Lock Screen widget).
    static func caption(_ d: ConnectedDevice) -> String {
        [d.name, d.battery.map(PowerItems.percent)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The connect notification's glyph, in the device's colour. Read live: the colour comes from
/// a BLE scan that can finish after the notification shows.
private struct DeviceGlyph: View {
    let device: ConnectedDevice

    var body: some View {
        let tint = DevicesState.shared.devices.first { $0.id == device.id }?.tint ?? device.tint
        BouncingSymbol(name: DeviceSymbol.resolve(device.symbol), color: tint.map { Color(nsColor: $0) } ?? Palette.ink, size: 17)
            .animation(.easeInOut(duration: 0.4), value: tint)
    }
}

enum DeviceSymbol {
    /// Falls back when a symbol name doesn't exist on this macOS.
    static func resolve(_ name: String, fallback: String = "headphones") -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }

    /// The first of `names` this macOS has (newer models' symbols are missing on older systems).
    static func first(_ names: [String]) -> String {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "headphones"
    }
}

/// The looping earbuds clip from the website, on the notch's black.
struct EarbudsVideo: NSViewRepresentable {
    static let url = Bundle.main.url(forResource: "earbuds", withExtension: "mp4", subdirectory: "Media")

    final class Coordinator {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        guard let url = Self.url else { return view }
        let c = context.coordinator
        c.looper = AVPlayerLooper(player: c.player, templateItem: AVPlayerItem(url: url))
        c.player.isMuted = true
        let layer = AVPlayerLayer(player: c.player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        c.player.play()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.player.pause() }
}
