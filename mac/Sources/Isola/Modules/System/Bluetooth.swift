import AppKit
import AVFoundation
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

    func start() {
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            track(d, announce: false)
        }
        // Every paired device's model, so renamed AirPods are recognised as they connect.
        fetchProfiler()
        // Battery levels drift; refresh them now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
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
        let device = ConnectedDevice(id: id, name: d.name ?? "Bluetooth device", symbol: kind.symbol, battery: levels.main, caseBattery: levels.case)
        connect(device, earbuds: kind.earbuds, announce: announce)
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

    private func checkBattery(_ device: ConnectedDevice, announce: Bool) {
        let prefs = SystemPreferences.shared
        guard let level = device.battery, prefs.deviceLowBattery else { return }
        if level > prefs.lowBatteryThreshold { warned[device.id] = 1; return }
        let last = warned[device.id] ?? 1
        for t in [prefs.lowBatteryThreshold, 0.1] where level <= t && t < last {
            warned[device.id] = t
            guard announce else { break }
            // Connection notification first, the warning right after it.
            let delay = Island.shared.transient?.id == "system.bluetooth" ? Preferences.shared.notificationDuration : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Island.shared.post(BluetoothItems.lowBattery(device), duration: 5)
                if prefs.deviceLowBatterySound { Sounds.lowBattery() }
            }
            break
        }
    }

    private func refreshBatteries() {
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            let id = Self.id(of: d)
            guard var device = DevicesState.shared.devices.first(where: { $0.id == id }) else { continue }
            let levels = Self.batteries(of: d)
            guard let main = levels.main else { continue }
            device.battery = main
            device.caseBattery = levels.case
            update(device)
        }
    }

    private func update(_ device: ConnectedDevice) {
        guard let i = DevicesState.shared.devices.firstIndex(where: { $0.id == device.id }) else { return }
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
        for (key, entry) in entries { if let id = entry.productID { productIDs[key] = id } }
        for var device in DevicesState.shared.devices {
            guard let entry = entries[Self.key(device.id)] else { continue }
            if let model = entry.productID.flatMap(Self.model) { device.symbol = model.symbol }
            if let main = entry.main {
                device.battery = main
                device.caseBattery = entry.case
            }
            update(device)
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
}

@MainActor
enum BluetoothItems {
    static func connected(_ device: ConnectedDevice, earbuds: Bool) -> IslandItem {
        IslandItem(id: "system.bluetooth", kind: .notification) {
            if earbuds, EarbudsVideo.url != nil, !SystemModule.renderingGallery {
                EarbudsVideo().frame(width: 32, height: 32).padding(.leading, 6).padding(.bottom, 2)
            } else {
                BouncingSymbol(name: DeviceSymbol.resolve(device.symbol), size: 17).padding(.leading, 11)
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
