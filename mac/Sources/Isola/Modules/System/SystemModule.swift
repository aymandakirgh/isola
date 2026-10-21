import SwiftUI

/// System events in the island: charging and battery, Low Power Mode, Bluetooth
/// devices, Focus, and screen lock/unlock.
@MainActor
enum SystemModule {
    static let renderingGallery = CommandLine.arguments.contains("--gallery")

    static func start() {
        registerSettings()
        PowerMonitor.shared.start()
        BluetoothMonitor.shared.start()
        FocusMonitor.shared.start()
        LockMonitor.start()
        registerDebug()
    }

    static func registerSettings() {
        SettingsRegistry.add("live", title: "Live Activities", symbol: "bolt.badge.clock", order: 30) { SystemSettingsView() }
    }

    // MARK: - isolactl simulations (this machine can't plug chargers or pair AirPods on cue)

    private static func registerDebug() {
        Debug.on("system.charging") { a in
            var r = PowerMonitor.read()
            r.hasBattery = true
            r.plugged = a["on"] != "0"
            r.charging = r.plugged
            if let level = a["level"].flatMap(Double.init) { r.level = level }
            r.toFull = r.plugged ? a["full"].flatMap(Int.init) ?? 72 : nil
            PowerMonitor.shared.simulate(r)
        }
        Debug.on("system.battery") { a in
            var r = PowerMonitor.read()
            r.hasBattery = true
            r.plugged = false
            r.charging = false
            r.level = a["level"].flatMap(Double.init) ?? 0.15
            PowerMonitor.shared.simulate(r)
        }
        Debug.on("system.lowpower") { a in
            let on = a["on"] != "0"
            PowerState.shared.lowPowerMode = !on
            PowerMonitor.shared.lowPowerChanged(on)
        }
        Debug.on("system.bluetooth") { a in
            let name = a["name"] ?? "AirPods Pro"
            var kind = BluetoothMonitor.classify(name: name)
            if let symbol = a["kind"] {
                kind.symbol = symbol
                kind.earbuds = ["airpods", "airpodspro", "beats.earphones", "earbuds"].contains(symbol)
            }
            let device = ConnectedDevice(
                id: "debug-\(name)", name: name, symbol: kind.symbol,
                battery: a["battery"].flatMap(Double.init), caseBattery: a["case"].flatMap(Double.init)
            )
            if a["on"] == "0" {
                BluetoothMonitor.shared.disconnect(device)
            } else {
                BluetoothMonitor.shared.connect(device, earbuds: kind.earbuds, announce: true)
            }
        }
        Debug.on("system.focus") { a in
            let name = a["name"] ?? "Work"
            let known = FocusMonitor.known.values.first { $0.name == name }
            let mode = FocusMonitor.Mode(
                id: "debug", name: name, symbol: a["symbol"] ?? known?.symbol ?? "moon.fill",
                tint: known?.tint ?? .systemIndigo
            )
            let monitor = FocusMonitor.shared
            monitor.pause(for: 30)
            if a["on"] == "0" {
                if monitor.current == nil { monitor.apply(mode, announce: false) }
                monitor.apply(nil, announce: true)
            } else {
                monitor.apply(mode, announce: true)
            }
        }
        Debug.on("system.lock") { _ in LockMonitor.locked() }
        Debug.on("system.unlock") { _ in LockMonitor.unlocked() }
    }

    // MARK: - Gallery

    static func gallery() {
        selfCheck()
        registerSettings()
        let airpods = ConnectedDevice(id: "a", name: "AirPods Pro", symbol: "airpodspro", battery: 0.76, caseBattery: 0.9)
        let speaker = ConnectedDevice(id: "b", name: "HomePod mini", symbol: "homepod.fill", battery: nil, caseBattery: nil)
        let headphones = ConnectedDevice(id: "c", name: "AirPods Max", symbol: "airpodsmax", battery: 0.09, caseBattery: nil)
        let work = FocusMonitor.known["com.apple.focus.work"]!
        let sleep = FocusMonitor.known["com.apple.sleep.sleep-mode"]!
        for (suffix, g) in [("pill", NotchGeometry.pillPreview), ("notch", NotchGeometry.notchPreview)] {
            Gallery.island("system-charger-on-\(suffix)", item: PowerItems.charger(connected: true, level: 0.84), geometry: g)
            Gallery.island("system-charger-off-\(suffix)", item: PowerItems.charger(connected: false, level: 0.62), geometry: g)
            Gallery.island("system-charging-\(suffix)", item: PowerItems.chargingActivity(level: 0.46, minutesToFull: 72), geometry: g)
            Gallery.island("system-charging-peek-\(suffix)", item: PowerItems.chargingActivity(level: 0.46, minutesToFull: 72), peeking: true, geometry: g)
            Gallery.island("system-low-battery-\(suffix)", item: PowerItems.lowBattery(level: 0.18), geometry: g)
            Gallery.island("system-low-power-on-\(suffix)", item: PowerItems.lowPower(on: true), geometry: g)
            Gallery.island("system-low-power-off-\(suffix)", item: PowerItems.lowPower(on: false), geometry: g)
            Gallery.island("system-bt-airpods-\(suffix)", item: BluetoothItems.connected(airpods, earbuds: true), geometry: g)
            Gallery.island("system-bt-airpods-peek-\(suffix)", item: BluetoothItems.connected(airpods, earbuds: true), peeking: true, geometry: g)
            Gallery.island("system-bt-speaker-\(suffix)", item: BluetoothItems.connected(speaker, earbuds: false), geometry: g)
            Gallery.island("system-bt-off-\(suffix)", item: BluetoothItems.disconnected(airpods), geometry: g)
            Gallery.island("system-bt-low-\(suffix)", item: BluetoothItems.lowBattery(headphones), geometry: g)
            Gallery.island("system-focus-on-\(suffix)", item: FocusItems.changed(work, on: true), geometry: g)
            Gallery.island("system-focus-off-\(suffix)", item: FocusItems.changed(sleep, on: false), geometry: g)
            Gallery.island("system-focus-activity-\(suffix)", item: FocusItems.activity(work), geometry: g)
            Gallery.island("system-lock-\(suffix)", item: LockMonitor.item(unlocked: false), geometry: g)
            Gallery.island("system-unlock-\(suffix)", item: LockMonitor.item(unlocked: true), geometry: g)
        }
        Gallery.add("system-lock-glyphs", size: CGSize(width: 160, height: 80)) {
            HStack(spacing: 24) {
                LockGlyph(unlocked: false, size: 48)
                LockGlyph(unlocked: true, size: 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        // Forms are AppKit-backed, which ImageRenderer can't draw: snapshot a real hosting view.
        let settings = snapshot(SystemSettingsView(), size: CGSize(width: 520, height: 860))
        Gallery.add("system-settings", size: CGSize(width: 520, height: 860)) { Image(nsImage: settings) }
    }

    /// Parser/classifier checks; runs with `Isola --gallery` (asserts trip in debug builds).
    private static func selfCheck() {
        let profiler = #"{"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{"device_address":"AA-BB-CC-DD-EE-FF","device_batteryLevelLeft":"76%","device_batteryLevelRight":"80%","device_batteryLevelCase":"90 %"}}]}]}"#
        let levels = BluetoothMonitor.profilerLevels(Data(profiler.utf8), address: "aa:bb:cc:dd:ee:ff")
        assert(levels?.main == 0.76 && levels?.case == 0.9, "profiler battery parse")
        assert(BluetoothMonitor.classify(name: "Ayman’s AirPods Pro") == ("airpodspro", true, true), "AirPods Pro")
        assert(BluetoothMonitor.classify(name: "Beats Studio Pro") == ("beats.headphones", true, false), "Beats over-ear")
        assert(BluetoothMonitor.classify(name: "Kitchen HomePod").symbol == "homepod.fill", "HomePod")
        let dnd = #"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}"#
        let json = try? JSONSerialization.jsonObject(with: Data(dnd.utf8))
        assert(FocusMonitor.firstValue("assertionDetailsModeIdentifier", in: json as Any) as? String == "com.apple.focus.work", "DND assertion")
        let config = #"{"data":[{"modeConfigurations":{"x":{"mode":{"modeIdentifier":"com.apple.focus.work","name":"Deep Work","symbolImageName":"laptopcomputer"}}}}]}"#
        let configJSON = try? JSONSerialization.jsonObject(with: Data(config.utf8))
        assert(FocusMonitor.modeDictionary("com.apple.focus.work", in: configJSON as Any)?["name"] as? String == "Deep Work", "DND config")
        assert(PowerItems.symbol(for: 0.05) == "battery.0percent" && PowerItems.symbol(for: 0.5) == "battery.50percent", "battery symbol")
        assert(PowerItems.minutes(72) == "1h 12m" && PowerItems.minutes(9) == "9 min", "minutes")
        let r = PowerMonitor.read()
        print("system self-check ok · battery=\(r.hasBattery) level=\(Int(r.level * 100))% plugged=\(r.plugged) charging=\(r.charging)")
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize) -> NSImage {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let image = NSImage(size: size)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}
