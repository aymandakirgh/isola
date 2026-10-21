import CoreBluetooth
import SwiftUI

/// System events in the island: charging and battery, Low Power Mode, Bluetooth
/// devices, Focus, and screen lock/unlock.
@MainActor
enum SystemModule {
    static let renderingGallery = CommandLine.arguments.contains("--gallery")

    static func start() {
        registerSettings()
        PowerMonitor.shared.start()
        startBluetoothWhenOnboarded()
        FocusMonitor.shared.start()
        LockMonitor.start()
        registerDebug()
    }

    static func registerSettings() {
        SettingsRegistry.add("live", title: "Live Activities", symbol: "bolt.badge.clock", order: 30) { SystemSettingsView() }
    }

    /// IOBluetooth blocks the main thread on the permission prompt while access is undecided,
    /// so start only once onboarding is done AND Bluetooth access is already granted (reading
    /// CBManager.authorization never prompts). The connect setting only gates announcements:
    /// device low-battery warnings and the Lock Screen connectivity widget need the monitor too.
    private static var bluetoothStarted = false

    static func startBluetoothIfAllowed() {
        guard !bluetoothStarted, UserDefaults.standard.bool(forKey: "onboarded"), CBManager.authorization == .allowedAlways else { return }
        bluetoothStarted = true
        BluetoothMonitor.shared.start()
    }

    private static func startBluetoothWhenOnboarded() {
        startBluetoothIfAllowed()
        // Onboarding answers the prompt (BluetoothPrompt); System Settings may grant it later.
        for name in [UserDefaults.didChangeNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { startBluetoothIfAllowed() }
            }
        }
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
            // `product=0x2027`: recognise a renamed device by its Apple product ID.
            let product = a["product"].flatMap { Int($0.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }
            var kind = product.flatMap(BluetoothMonitor.model) ?? BluetoothMonitor.classify(name: name)
            if let symbol = a["kind"] {
                kind.symbol = symbol
                kind.earbuds = ["airpods", "airpods.gen3", "airpods.gen4", "airpods.pro", "airpodspro", "beats.earphones", "earbuds"].contains(symbol)
            }
            // `color=pink` (or the pairing-card label `red`, or the code `0x02`): an AirPods Max
            // colour, as its BLE advertisement would report it.
            let device = ConnectedDevice(
                id: "debug-\(name)", name: name, symbol: kind.symbol,
                battery: a["battery"].flatMap(Double.init), caseBattery: a["case"].flatMap(Double.init),
                tint: a["color"].flatMap(BluetoothMonitor.maxTint)
            )
            if a["on"] == "0" {
                BluetoothMonitor.shared.disconnect(device)
            } else {
                // A simulation always shows, even with real device notifications turned off.
                BluetoothMonitor.shared.connect(device, earbuds: kind.earbuds, announce: false)
                Island.shared.post(BluetoothItems.connected(device, earbuds: kind.earbuds))
            }
        }
        Debug.on("system.devicebattery") { a in
            // A new level for a connected (or simulated) device, as the 10 s battery poll reads it.
            let name = a["name"] ?? "AirPods Pro"
            guard var device = DevicesState.shared.devices.first(where: { $0.name == name }) else { return }
            device.battery = a["level"].flatMap(Double.init) ?? 0.15
            BluetoothMonitor.shared.update(device)
        }
        Debug.on("system.focus") { a in
            let name = a["name"] ?? "Work"
            // A known name keeps its mode id, so `name=Sleep` also plays the Sleep sound.
            let known = FocusMonitor.known.first { $0.value.name == name }
            let mode = FocusMonitor.Mode(
                id: known?.key ?? "debug", name: name, symbol: a["symbol"] ?? known?.value.symbol ?? "moon.fill",
                tint: known?.value.tint ?? .systemIndigo
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
        ProximityPairing.selfCheck()
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
            Gallery.island("system-charging-details-\(suffix)", item: PowerItems.chargingActivity(level: 0.46, minutesToFull: 72, watts: 96, details: true), peeking: true, geometry: g)
            Gallery.island("system-low-battery-\(suffix)", item: PowerItems.lowBattery(level: 0.18), geometry: g)
            Gallery.island("system-low-power-on-\(suffix)", item: PowerItems.lowPower(on: true), geometry: g)
            Gallery.island("system-low-power-off-\(suffix)", item: PowerItems.lowPower(on: false), geometry: g)
            Gallery.island("system-bt-airpods-\(suffix)", item: BluetoothItems.connected(airpods, earbuds: true), geometry: g)
            Gallery.island("system-bt-airpods-peek-\(suffix)", item: BluetoothItems.connected(airpods, earbuds: true), peeking: true, geometry: g)
            Gallery.island("system-bt-speaker-\(suffix)", item: BluetoothItems.connected(speaker, earbuds: false), geometry: g)
            Gallery.island("system-bt-off-\(suffix)", item: BluetoothItems.disconnected(airpods), geometry: g)
            Gallery.island("system-bt-low-\(suffix)", item: BluetoothItems.lowBattery(headphones), geometry: g)
            // AirPods Max in each colour their advertisement can name, by the pairing-card label.
            for color in BluetoothMonitor.maxColors.values {
                let airpodsMax = ConnectedDevice(id: "m", name: "AirPods Max", symbol: DeviceSymbol.first(["airpods.max", "airpodsmax"]), battery: 0.8, caseBattery: nil, tint: color.tint)
                let label = color.label.lowercased().replacingOccurrences(of: " ", with: "")
                Gallery.island("system-bt-airpodsmax-\(label)-\(suffix)", item: BluetoothItems.connected(airpodsMax, earbuds: false), geometry: g)
            }
            Gallery.island("system-focus-on-\(suffix)", item: FocusItems.changed(work, on: true), geometry: g)
            Gallery.island("system-focus-off-\(suffix)", item: FocusItems.changed(sleep, on: false), geometry: g)
            Gallery.island("system-focus-activity-\(suffix)", item: FocusItems.activity(work), geometry: g)
            Gallery.island("system-focus-activity-peek-\(suffix)", item: FocusItems.activity(work), peeking: true, geometry: g)
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
        let settings = snapshot(SystemSettingsView(), size: CGSize(width: 520, height: 1000))
        Gallery.add("system-settings", size: CGSize(width: 520, height: 1000)) { Image(nsImage: settings) }
    }

    /// Parser/classifier checks; runs with `Isola --gallery` (asserts trip in debug builds).
    private static func selfCheck() {
        let profiler = #"{"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{"device_address":"AA-BB-CC-DD-EE-FF","device_batteryLevelLeft":"76%","device_batteryLevelRight":"80%","device_batteryLevelCase":"90 %","device_productID":"0x2014","device_vendorID":"0x004C"}}],"device_not_connected":[{"Kitchen":{"device_address":"11:22:33:44:55:66","device_productID":"0x2027","device_vendorID":"0x004C"}},{"Speaker":{"device_address":"22:22:33:44:55:66","device_productID":"0x2014","device_vendorID":"0x0A12"}}]}]}"#
        let paired = BluetoothMonitor.profilerDevices(Data(profiler.utf8))
        let pods = paired[BluetoothMonitor.key("aa-bb-cc-dd-ee-ff")]
        precondition(pods?.main == 0.76 && pods?.case == 0.9 && pods?.productID == 0x2014, "profiler battery and product ID")
        precondition(paired["11:22:33:44:55:66"]?.productID == 0x2027 && paired["11:22:33:44:55:66"]?.main == nil, "paired but not connected")
        precondition(paired["22:22:33:44:55:66"] != nil && paired["22:22:33:44:55:66"]?.productID == nil, "product IDs only under Apple's vendor ID")
        let pro = DeviceSymbol.first(["airpods.pro", "airpodspro"])
        precondition(BluetoothMonitor.model(0x2027).map { $0.symbol == pro && $0.earbuds } == true, "renamed AirPods Pro 3 by product ID")
        precondition(BluetoothMonitor.model(0x201F)?.earbuds == false && BluetoothMonitor.model(0x1234) == nil, "AirPods Max (USB-C); unknown IDs fall back")
        precondition(BluetoothMonitor.models.values.allSatisfy { DeviceSymbol.first($0.symbols) != "headphones" }, "every model has a symbol on this macOS")
        assert(BluetoothMonitor.classify(name: "Ayman’s AirPods Pro") == (pro, true, true), "AirPods Pro")
        assert(BluetoothMonitor.classify(name: "Beats Studio Pro") == ("beats.headphones", true, false), "Beats over-ear")
        assert(BluetoothMonitor.classify(name: "Kitchen HomePod").symbol == "homepod.fill", "HomePod")
        let dnd = #"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}"#
        let json = try? JSONSerialization.jsonObject(with: Data(dnd.utf8))
        assert(FocusMonitor.firstValue("assertionDetailsModeIdentifier", in: json as Any) as? String == "com.apple.focus.work", "DND assertion")
        let config = #"{"data":[{"modeConfigurations":{"x":{"mode":{"modeIdentifier":"com.apple.focus.work","name":"Deep Work","symbolImageName":"laptopcomputer"}}}}]}"#
        let configJSON = try? JSONSerialization.jsonObject(with: Data(config.utf8))
        assert(FocusMonitor.modeDictionary("com.apple.focus.work", in: configJSON as Any)?["name"] as? String == "Deep Work", "DND config")
        for (language, sleep) in ["it": "Sonno", "de": "Schlafen", "fr": "Repos", "es": "Descanso", "en": "Sleep"] {
            precondition(FocusL10n.text("Sleep", language: language) == sleep, "Focus name in \(language)")
        }
        precondition(FocusL10n.text("Deep Work", language: "it") == "Deep Work", "custom names stay as they are")
        precondition(FocusL10n.language(for: ["it-IT", "en-US"]) == "it" && FocusL10n.language(for: ["nl-NL", "de-DE"]) == "de"
            && FocusL10n.language(for: ["ja-JP"]) == "en", "Focus language pick")
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
