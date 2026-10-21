import AppKit
import ApplicationServices
import CoreAudio
import Observation
import SwiftUI

enum HUDStyle: String, CaseIterable, Identifiable {
    case bar, percentage, decibels
    var id: String { rawValue }
    var title: String { self == .bar ? "Bar" : self == .percentage ? "Percentage" : "Decibels" }
}

enum HUDKind: String { case volume, brightness }

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }

@MainActor @Observable
final class HUDPreferences {
    static let shared = HUDPreferences()

    /// Take over the volume/brightness keys so the macOS HUD never shows (needs Accessibility).
    var replaceSystemHUD: Bool = load("hud.replaceSystemHUD", false) {
        didSet { store.set(replaceSystemHUD, forKey: "hud.replaceSystemHUD"); HUDModule.updateTap() }
    }
    var style: HUDStyle = HUDStyle(rawValue: store.string(forKey: "hud.style") ?? "") ?? .bar {
        didSet { store.set(style.rawValue, forKey: "hud.style") }
    }
    /// "Volume" / "Brightness" (or the output device) with a full-width bar under the notch.
    var showLabels: Bool = load("hud.showLabels", true) { didSet { store.set(showLabels, forKey: "hud.showLabels") } }
    var glow: Bool = load("hud.glow", true) { didSet { store.set(glow, forKey: "hud.glow") } }
    var displaySymbol: Bool = load("hud.displaySymbol", false) { didSet { store.set(displaySymbol, forKey: "hud.displaySymbol") } }
    var duration: Double = load("hud.duration", 1.5) { didSet { store.set(duration, forKey: "hud.duration") } }
    /// Sync: also show the HUD for volume changed elsewhere (other apps, Control Center,
    /// AirPods), not only for key presses. Telling them apart needs the key tap.
    var showExternalChanges: Bool = load("hud.showExternalChanges", true) {
        didSet { store.set(showExternalChanges, forKey: "hud.showExternalChanges") }
    }
    /// Brightness and volume of displays BetterDisplay drives, from its OSD notifications.
    var betterDisplay: Bool = load("hud.betterDisplay", true) { didSet { store.set(betterDisplay, forKey: "hud.betterDisplay") } }
    /// Defaults to the system "Play feedback when volume is changed" setting.
    var feedbackSound: Bool = load("hud.feedbackSound", (store.object(forKey: "com.apple.sound.beep.feedback") as? Int ?? 0) == 1) {
        didSet { store.set(feedbackSound, forKey: "hud.feedbackSound") }
    }

    var look: HUDLook { HUDLook(style: style, labels: showLabels, glow: glow, displaySymbol: displaySymbol) }
}

/// What a HUD shows; a plain value so gallery snapshots don't depend on live state.
struct HUDSnapshot {
    var kind: HUDKind = .volume
    var level: Double = 0.5
    var muted = false
    var decibels: Double?
    var output = HUDOutput(name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil)
    var displayName = "Built-in Display"
}

struct HUDLook {
    var style: HUDStyle = .bar
    var labels = true
    var glow = true
    var displaySymbol = false
}

/// An output device as the HUD presents it.
struct HUDOutput: Equatable {
    var name: String
    var transport: UInt32
    var dataSource: UInt32?
    /// Symbol of the Bluetooth device Isola recognised by product ID (renamed AirPods too).
    var deviceSymbol: String?
    /// CoreAudio model UID.
    var model: String?

    /// Device glyph, or nil for plain speakers (drawn as level-aware speaker waves).
    var symbol: String? {
        if let deviceSymbol { return deviceSymbol }
        let byName = BluetoothMonitor.classify(name: name)
        if byName.audio { return byName.symbol }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            // A HomePod named after its room: CoreAudio's model may still say HomePod (its
            // product type is AudioAccessoryN,N; 5 is the mini).
            guard let model, model.contains("HomePod") || model.hasPrefix("AudioAccessory") else { return "airplayaudio" }
            return model.hasPrefix("AudioAccessory5") || model.contains("mini") ? "homepod.mini.fill" : "homepod.fill"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeBuiltIn where dataSource == 0x6864_706E: return "headphones"  // 'hdpn'
        default: return nil
        }
    }

    /// HUD label: "Volume" for the Mac's own speakers, else the device (minus the Mac model).
    var label: String {
        guard symbol != nil else { return "Volume" }
        let prefixes = ["MacBook Pro ", "MacBook Air ", "MacBook ", "iMac ", "Mac mini ", "Mac Studio ", "Mac Pro "]
        return prefixes.reduce(name) { $0.hasPrefix($1) ? String($0.dropFirst($1.count)) : $0 }
    }

    /// Typical macOS curve (power-of-two amplitude, -63.5 dB floor).
    static func approximateDecibels(_ scalar: Double) -> Double {
        scalar <= 0 ? -63.5 : max(-63.5, 40 * log10(scalar))
    }

    /// `device=` values understood by the debug command.
    static func preset(_ key: String) -> HUDOutput {
        switch key.lowercased() {
        case "airpods": HUDOutput(name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
        case "airpodspro": HUDOutput(name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        case "airpodsmax": HUDOutput(name: "AirPods Max", transport: kAudioDeviceTransportTypeBluetooth)
        case "headphones": HUDOutput(name: "Headphones", transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6864_706E)
        case "beats": HUDOutput(name: "Beats Studio Pro", transport: kAudioDeviceTransportTypeBluetooth)
        case "homepod": HUDOutput(name: "HomePod", transport: kAudioDeviceTransportTypeAirPlay)
        case "airplay": HUDOutput(name: "Living Room", transport: kAudioDeviceTransportTypeAirPlay)
        case "display": HUDOutput(name: "LG UltraFine", transport: kAudioDeviceTransportTypeDisplayPort)
        default: HUDOutput(name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
        }
    }

    init(name: String, transport: UInt32, dataSource: UInt32? = nil, deviceSymbol: String? = nil, model: String? = nil) {
        self.name = name
        self.transport = transport
        self.dataSource = dataSource
        self.deviceSymbol = deviceSymbol
        self.model = model
    }
}

/// Live HUD state the island views observe.
@MainActor @Observable
final class HUDModel {
    static let shared = HUDModel()
    var snapshot = HUDSnapshot()
    var accessibilityTrusted = AXIsProcessTrusted()
    /// Rubber band from pushing past 0% or 100%: 1 fully stretched, 0 at rest.
    var stretch: Double = 0
}

@MainActor
enum HUDModule {
    private static var lastVolume: (level: Double, muted: Bool)?
    private static var ready = false

    static func start() {
        registerSettings()
        registerDebug()
        if let v = SystemAudio.volume() { lastVolume = (v, SystemAudio.isMuted()) }
        SystemAudio.observe { volumeChanged() }
        DistributedNotificationCenter.default().addObserver(forName: BetterDisplayOSD.notification, object: nil, queue: .main) { note in
            guard let json = note.object as? String, let osd = try? JSONDecoder().decode(BetterDisplayOSD.self, from: Data(json.utf8)) else { return }
            MainActor.assumeIsolated {
                if HUDPreferences.shared.betterDisplay, let snapshot = osd.snapshot() { show(snapshot) }
            }
        }
        updateTap()
        // Accessibility can be granted at any time in System Settings.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { updateTap() } }
        // Ignore the burst of notifications some devices send while listeners attach.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready = true }
    }

    static func registerSettings() {
        SettingsRegistry.add("hud", title: "HUDs", symbol: "slider.horizontal.3", order: 40) { HUDSettingsView() }
    }

    static func updateTap() {
        let trusted = AXIsProcessTrusted()
        if HUDModel.shared.accessibilityTrusted != trusted { HUDModel.shared.accessibilityTrusted = trusted }
        if HUDPreferences.shared.replaceSystemHUD && trusted { MediaKeyTap.shared.install() } else { MediaKeyTap.shared.remove() }
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        updateTap()
    }

    // MARK: Showing

    static func item(_ kind: HUDKind) -> IslandItem {
        let item = IslandItem(id: "hud.\(kind.rawValue)", kind: .hud) {
            LiveHUD(part: .leading)
        } trailing: {
            LiveHUD(part: .trailing)
        }
        return HUDPreferences.shared.showLabels ? item.peek(always: true) { LiveHUD(part: .label) } : item
    }

    static func show(_ snapshot: HUDSnapshot) {
        HUDModel.shared.snapshot = snapshot
        Island.shared.post(item(snapshot.kind), duration: HUDPreferences.shared.duration)
    }

    /// Passive path: any volume/mute change on the output device.
    private static func volumeChanged() {
        guard let level = SystemAudio.volume() else { return }
        let muted = SystemAudio.isMuted()
        defer { lastVolume = (level, muted) }
        guard ready, let last = lastVolume, abs(last.level - level) > 0.001 || last.muted != muted, syncsExternalChanges else { return }
        showVolume(level: level, muted: muted)
    }

    /// Key presses show the HUD themselves (MediaKeyTap); everything else reaching the
    /// passive path was changed elsewhere. Without the tap, key presses arrive here too.
    private static var syncsExternalChanges: Bool {
        !MediaKeyTap.shared.isInstalled || HUDPreferences.shared.showExternalChanges
    }

    private static func showVolume(level: Double, muted: Bool) {
        show(HUDSnapshot(kind: .volume, level: level, muted: muted, decibels: SystemAudio.decibels(for: level), output: SystemAudio.output()))
    }

    // MARK: Key handling (event tap)

    /// Next level on the macOS grid: 16 steps, or 64 with Option+Shift.
    nonisolated static func stepped(_ current: Double, up: Bool, fine: Bool) -> Double {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        return min(1, max(0, ((current / step).rounded() + (up ? 1 : -1)) * step))
    }

    /// Returns true when the key was handled, so the tap swallows it (no macOS HUD).
    static func handle(_ key: MediaKey, down: Bool, fine: Bool, alternate: Bool, shift: Bool) -> Bool {
        switch key {
        case .volumeUp, .volumeDown:
            guard SystemAudio.canSetVolume(), let current = SystemAudio.volume() else { return false }
            guard down else {
                if HUDPreferences.shared.feedbackSound != shift { playFeedback() }
                return true
            }
            let level = stepped(current, up: key == .volumeUp, fine: fine)
            if key == .volumeUp, SystemAudio.isMuted() { SystemAudio.setMuted(false) }
            SystemAudio.setVolume(level)
            showVolume(level: level, muted: SystemAudio.isMuted())
            if level == current { rubberBand() }  // stepped() only stays put at 0% or 100%
            return true
        case .mute:
            if down {
                SystemAudio.setMuted(!SystemAudio.isMuted())
                showVolume(level: SystemAudio.volume() ?? 0, muted: SystemAudio.isMuted())
            }
            return true
        case .brightnessUp, .brightnessDown:
            guard let screen = DisplayBrightness.target(alternate: alternate), let current = DisplayBrightness.get(screen.displayID) else { return false }
            guard down else { return true }
            let level = stepped(current, up: key == .brightnessUp, fine: fine)
            DisplayBrightness.set(screen.displayID, level)
            show(HUDSnapshot(kind: .brightness, level: level, displayName: screen.isBuiltIn ? "Built-in Display" : screen.localizedName))
            if level == current { rubberBand() }
            return true
        }
    }

    /// Pushing past 0% or 100% stretches the bar toward the push and lets it spring back,
    /// only with the island's Overshoot on.
    private static func rubberBand() {
        guard Preferences.shared.overshoot else { return }
        withAnimation(.easeOut(duration: 0.08)) { HUDModel.shared.stretch = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(Springs.spring(300, 9)) { HUDModel.shared.stretch = 0 }
        }
    }

    /// The same "pop" macOS plays on key release when volume feedback is on.
    private static let feedback = NSSound(contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference: true)

    private static func playFeedback() {
        feedback?.stop()
        feedback?.play()
    }

    // MARK: Debug + gallery

    private static func registerDebug() {
        // Simulated: shows the HUD without touching the real volume or brightness.
        // `push=1` also plays the rubber band, as a key press at 0% or 100% does;
        // `elsewhere=1` goes through the sync setting like a change from another app.
        Debug.on("hud.volume") { args in
            if args["elsewhere"] == "1", !syncsExternalChanges { return }
            let level = args["level"].flatMap(Double.init) ?? 0.5
            let output = args["device"].map(HUDOutput.preset) ?? HUDOutput.preset("speakers")
            show(HUDSnapshot(kind: .volume, level: level, muted: args["muted"] == "1", decibels: HUDOutput.approximateDecibels(level), output: output))
            if args["push"] == "1" { rubberBand() }
        }
        Debug.on("hud.brightness") { args in
            show(HUDSnapshot(kind: .brightness, level: args["level"].flatMap(Double.init) ?? 0.6))
            if args["push"] == "1" { rubberBand() }
        }
        // Posts what BetterDisplay posts (other apps listening for it see it too), so the
        // observer and decoding run: `target=hardwareBrightness|volume|mute value=40 max=100`.
        Debug.on("hud.betterdisplay") { args in
            let osd: [String: Any] = [
                "controlTarget": args["target"] ?? "hardwareBrightness",
                "value": args["value"].flatMap(Double.init) ?? 60, "maxValue": args["max"].flatMap(Double.init) ?? 100,
                "displayID": args["display"].flatMap(Int.init) ?? Int(NSScreen.main?.displayID ?? 0),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: osd), let json = String(data: data, encoding: .utf8) else { return }
            DistributedNotificationCenter.default().postNotificationName(BetterDisplayOSD.notification, object: json, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Pure-logic checks; run with every gallery render (debug build asserts).
    static func selfCheck() {
        assert(stepped(0.5, up: true, fine: false) == 0.5625)
        assert(stepped(0.51, up: false, fine: false) == 0.4375)  // snaps to the grid first
        assert(stepped(1, up: true, fine: false) == 1 && stepped(0, up: false, fine: false) == 0)
        assert(stepped(0.5, up: true, fine: true) == 0.515625)
        assert(HUDOutput.preset("speakers").symbol == nil && HUDOutput.preset("speakers").label == "Volume")
        assert(HUDOutput.preset("airpodspro").symbol == DeviceSymbol.first(["airpods.pro", "airpodspro"]) && HUDOutput.preset("airpodspro").label == "AirPods Pro")
        let airPlay = kAudioDeviceTransportTypeAirPlay
        precondition(HUDOutput(name: "Living Room", transport: airPlay, model: "AudioAccessory5,1").symbol == "homepod.mini.fill"
            && HUDOutput(name: "Living Room", transport: airPlay, model: "AppleTV11,1").symbol == "airplayaudio", "HomePod by CoreAudio model")
        precondition(HUDOutput(name: "Kitchen", transport: kAudioDeviceTransportTypeBluetooth, deviceSymbol: "airpods.max").label == "Kitchen", "renamed device keeps its name")
        assert(HUDOutput(name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6864_706E).label == "Speakers")
        assert(abs(HUDOutput.approximateDecibels(0.5) + 12.04) < 0.01 && HUDOutput.approximateDecibels(0) == -63.5)
        func osd(_ json: String) -> HUDSnapshot? { (try? JSONDecoder().decode(BetterDisplayOSD.self, from: Data(json.utf8)))?.snapshot() }
        let brightness = osd(#"{"displayID":1,"systemIconID":1,"controlTarget":"hardwareBrightness","value":40,"maxValue":100}"#)
        precondition(brightness?.kind == .brightness && brightness?.level == 0.4, "BetterDisplay brightness")
        let volume = osd(#"{"systemIconID":3,"controlTarget":"volume","value":0.25,"maxValue":1}"#)
        precondition(volume?.kind == .volume && volume?.level == 0.25 && volume?.muted == false && volume?.output.symbol == "tv", "BetterDisplay volume")
        precondition(osd(#"{"systemIconID":4,"controlTarget":"mute"}"#)?.muted == true, "BetterDisplay mute, no level")
        precondition(osd(#"{"controlTarget":"contrast","value":50,"maxValue":100}"#) == nil && osd(#"{"controlTarget":"softwareBrightness","value":0.5}"#) == nil,
            "BetterDisplay: no HUD for other controls or a level without maximum")
    }

    static func gallery() {
        selfCheck()
        registerSettings()
        func add(_ name: String, _ s: HUDSnapshot, _ look: HUDLook = HUDLook(), geometry: NotchGeometry = .pillPreview, stretch: Double = 0) {
            var item = IslandItem(id: "hud", kind: .hud) {
                HUDPart(part: .leading, s: s, look: look)
            } trailing: {
                HUDPart(part: .trailing, s: s, look: look, stretch: stretch)
            }
            if look.labels { item = item.peek(always: true) { HUDPart(part: .label, s: s, look: look, stretch: stretch) } }
            Gallery.island("hud-\(name)", item: item, geometry: geometry)
        }
        func volume(_ level: Double, muted: Bool = false, device: String = "speakers") -> HUDSnapshot {
            HUDSnapshot(kind: .volume, level: level, muted: muted, decibels: HUDOutput.approximateDecibels(level), output: .preset(device))
        }
        let compact = HUDLook(labels: false)
        add("volume-low", volume(0.19))
        add("volume-mid", volume(0.5))
        add("volume-high", volume(0.94))
        add("volume-muted", volume(0.5, muted: true))
        add("volume-airpodspro", volume(0.62, device: "airpodspro"))
        add("volume-airpodsmax-notch", volume(0.4, device: "airpodsmax"), geometry: .notchPreview)
        add("volume-notch", volume(0.5), geometry: .notchPreview)
        add("style-bar-compact", volume(0.5), compact)
        add("style-bar-compact-notch", volume(0.5), compact, geometry: .notchPreview)
        add("style-percentage-compact", volume(0.75), HUDLook(style: .percentage, labels: false))
        add("style-decibels-compact", volume(0.5), HUDLook(style: .decibels, labels: false))
        add("style-decibels-labels", volume(0.5), HUDLook(style: .decibels))
        add("style-percentage-muted", volume(0.5, muted: true), HUDLook(style: .percentage, labels: false))
        add("brightness-glow", HUDSnapshot(kind: .brightness, level: 0.8))
        add("brightness-low", HUDSnapshot(kind: .brightness, level: 0.2))
        add("brightness-display-symbol", HUDSnapshot(kind: .brightness, level: 0.55), HUDLook(displaySymbol: true))
        add("brightness-compact-notch", HUDSnapshot(kind: .brightness, level: 0.7), compact, geometry: .notchPreview)
        // Peak of the rubber band when pushing past the ends.
        add("overshoot-volume-max", volume(1), stretch: 1)
        add("overshoot-volume-min-compact", volume(0), compact, stretch: 1)
        add("overshoot-brightness-max-compact-notch", HUDSnapshot(kind: .brightness, level: 1), compact, geometry: .notchPreview, stretch: 1)
        snapshotSettings()
    }

    /// Forms are AppKit-backed, which ImageRenderer can't draw: render the settings page
    /// through an offscreen hosting view into the gallery folder instead.
    private static func snapshotSettings() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--gallery"), i + 1 < args.count else { return }
        let size = NSRect(x: 0, y: 0, width: 520, height: 1040)
        let host = NSHostingView(rootView: HUDSettingsView().frame(width: size.width, height: size.height))
        host.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size.size
        host.cacheDisplay(in: size, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]).appendingPathComponent("hud-settings.png"))
    }
}
