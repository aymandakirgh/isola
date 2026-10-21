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
    private var startedAt = Date.distantFuture
    private var timer: Timer?

    func start() {
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            track(d, announce: false)
        }
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
        let kind = Self.classify(d)
        guard kind.audio || SystemPreferences.shared.bluetoothAllDevices else { return }
        let id = Self.id(of: d)
        if disconnectNotes[id] == nil {
            disconnectNotes[id] = d.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        }
        let levels = Self.batteries(of: d)
        let device = ConnectedDevice(id: id, name: d.name ?? "Bluetooth device", symbol: kind.symbol, battery: levels.main, caseBattery: levels.case)
        connect(device, earbuds: kind.earbuds, announce: announce)
        if levels.main == nil { fetchBatteriesFromProfiler(address: d.addressString) }
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

    /// SF Symbol plus whether it is an audio device and in-ear (gets the earbuds clip).
    nonisolated static func classify(_ d: IOBluetoothDevice) -> (symbol: String, audio: Bool, earbuds: Bool) {
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

    nonisolated static func classify(name raw: String) -> (symbol: String, audio: Bool, earbuds: Bool) {
        let name = raw.lowercased()
        if name.contains("airpods max") { return ("airpodsmax", true, false) }
        if name.contains("airpods pro") { return ("airpodspro", true, true) }
        if name.contains("airpods") { return ("airpods", true, true) }
        if name.contains("beats") {
            let overEar = name.contains("studio") || name.contains("solo")
            return (overEar ? "beats.headphones" : "beats.earphones", true, !overEar)
        }
        if name.contains("homepod") { return ("homepod.fill", true, false) }
        if name.contains("earpods") || name.contains("buds") { return ("earbuds", true, true) }
        return ("headphones", false, false)
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

    /// Fallback for accessories IOBluetooth won't report: ask system_profiler once, off the main thread.
    private func fetchBatteriesFromProfiler(address: String?) {
        guard let address else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let levels = Self.profilerLevels(data, address: address) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let monitor = BluetoothMonitor.shared
                    guard var device = DevicesState.shared.devices.first(where: { $0.id == address }) else { return }
                    device.battery = levels.main
                    device.caseBattery = levels.case
                    monitor.update(device)
                }
            }
        }
    }

    /// Parses `system_profiler SPBluetoothDataType -json` for one device's battery levels.
    nonisolated static func profilerLevels(_ data: Data, address: String) -> (main: Double, case: Double?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let normalized = address.uppercased().replacingOccurrences(of: "-", with: ":")
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for case let info as [String: Any] in entry.values {
                    guard (info["device_address"] as? String)?.uppercased().replacingOccurrences(of: "-", with: ":") == normalized else { continue }
                    func pct(_ k: String) -> Double? { (info[k] as? String).flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }.map { $0 / 100 } }
                    let main = pct("device_batteryLevelMain") ?? [pct("device_batteryLevelLeft"), pct("device_batteryLevelRight")].compactMap { $0 }.min()
                    guard let main else { return nil }
                    return (main, pct("device_batteryLevelCase"))
                }
            }
        }
        return nil
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
