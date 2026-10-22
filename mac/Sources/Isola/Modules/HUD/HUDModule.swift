import AppKit
import ApplicationServices
import CoreAudio
import Observation
import SwiftUI

/// How a HUD's level shows: white, the system accent colour, a gradient of the HUD's own, or a
/// style only one HUD has (the Display HUD's glow, the Sound HUD's decibels).
enum HUDProgressStyle: String, CaseIterable, Identifiable {
    case white, accent, stylized, glow, decibel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: "White"
        case .accent: "Accent colour"
        case .stylized: "Gradient"
        case .glow: "Glow"
        case .decibel: "Decibels"
        }
    }

    func fits(_ kind: HUDKind) -> Bool {
        switch self {
        case .glow: kind == .brightness
        case .decibel: kind == .volume
        default: true
        }
    }
}

enum HUDKind: String, CaseIterable, Identifiable {
    case volume, brightness
    var id: String { rawValue }
    /// Its page in HUDs settings.
    var title: String { self == .volume ? "Sound" : "Display" }
}

/// What the Sound HUD pictures: the output device (its glyph and name), or always the speaker.
enum HUDOutputStyle: String, CaseIterable, Identifiable {
    case device, symbol
    var id: String { rawValue }
    var title: String { self == .device ? "Show device" : "Show speaker symbol" }
}

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }

@MainActor @Observable
final class HUDPreferences {
    static let shared = HUDPreferences()

    /// Take over the volume/brightness keys so the macOS HUD never shows (needs Accessibility).
    var replaceSystemHUD: Bool = load("hud.replaceSystemHUD", false) {
        didSet { store.set(replaceSystemHUD, forKey: "hud.replaceSystemHUD"); HUDModule.updateTap() }
    }
    /// Each HUD's own look (HUDs › Sound and Display); read it through `look(_:)`.
    var volume = HUDLook.saved(.volume) { didSet { volume.save(.volume) } }
    var brightness = HUDLook.saved(.brightness) { didSet { brightness.save(.brightness) } }
    /// Link settings between HUDs: an edit on either page lands on both.
    var linked: Bool = load("hud.linked", true) { didSet { store.set(linked, forKey: "hud.linked") } }
    var displaySymbol: Bool = load("hud.displaySymbol", false) { didSet { store.set(displaySymbol, forKey: "hud.displaySymbol") } }
    var outputStyle: HUDOutputStyle = HUDOutputStyle(rawValue: store.string(forKey: "hud.outputStyle") ?? "") ?? .device {
        didSet { store.set(outputStyle.rawValue, forKey: "hud.outputStyle") }
    }
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
    /// The HUD the settings page shows (not saved).
    var page: HUDKind = .volume

    /// What one HUD looks like now.
    func look(_ kind: HUDKind) -> HUDLook {
        var look = kind == .volume ? volume : brightness
        if !look.style.fits(kind) { look.style = .white }  // a synced value meant for the other HUD
        look.displaySymbol = displaySymbol
        look.output = outputStyle
        return look
    }

    /// A settings edit to one HUD; with Link on the other takes it too.
    func edit<V>(_ kind: HUDKind, _ path: WritableKeyPath<HUDLook, V>, _ value: V) {
        let r = Self.edit((volume, brightness), kind, path, value, linked: linked)
        if r.volume != volume { volume = r.volume }
        if r.brightness != brightness { brightness = r.brightness }
    }

    /// An edit on `kind`'s page as each HUD takes it: with Link on both do, except that a HUD never
    /// takes a style it doesn't have (glow, decibels).
    nonisolated static func edit<V>(_ looks: (volume: HUDLook, brightness: HUDLook), _ kind: HUDKind, _ path: WritableKeyPath<HUDLook, V>, _ value: V, linked: Bool) -> (volume: HUDLook, brightness: HUDLook) {
        var r = looks
        for k in linked ? HUDKind.allCases : [kind] {
            var look = k == .volume ? r.volume : r.brightness
            look[keyPath: path] = value
            guard look.style.fits(k) else { continue }
            if k == .volume { r.volume = look } else { r.brightness = look }
        }
        return r
    }

    /// Turning Link on starts both HUDs from `kind`'s look (the other keeps a style it can't share).
    func link(from kind: HUDKind) {
        linked = true
        let other: HUDKind = kind == .volume ? .brightness : .volume
        var look = kind == .volume ? volume : brightness
        if !look.style.fits(other) { look.style = (other == .volume ? volume : brightness).style }
        if other == .volume { volume = look } else { brightness = look }
    }
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

/// One HUD's appearance and motion; a plain value so gallery snapshots don't depend on live state.
struct HUDLook: Equatable {
    var style: HUDProgressStyle = .white
    var showPercentage = true
    var labels = true
    var duration: Double = 1.5
    var speed: AnimationSpeed = .smooth
    /// Not saved per HUD: `HUDPreferences.look(_:)` fills them in.
    var displaySymbol = false
    var output: HUDOutputStyle = .device

    /// The HUD's own spring, scaled by its speed (the island's Overshoot still applies).
    @MainActor func spring(_ stiffness: Double, _ damping: Double) -> Animation {
        let f = speed.factor
        let d = Preferences.shared.overshoot ? damping : max(damping, 2 * stiffness.squareRoot())
        return .interpolatingSpring(mass: 1, stiffness: stiffness * f, damping: d * f.squareRoot())
    }

    /// The HUD springing in and out: the island's expand and notification-collapse springs, at the HUD's speed.
    @MainActor var motion: Animation { spring(150, 20) }
    @MainActor var collapse: Animation { spring(150, 16) }

    /// The bar filling: LevelBar's spring, at the HUD's speed.
    var fillSpring: Animation {
        .interpolatingSpring(mass: 1, stiffness: 300 * speed.factor, damping: 30 * speed.factor.squareRoot())
    }

    /// A HUD's saved look. Before each HUD had its own, both shared "hud.style" (bar, percentage
    /// or decibels), "hud.showLabels" (with labels the number sat in the wing) and "hud.duration",
    /// moved at the island's "speed", and the Display HUD had "hud.glow".
    static func saved(_ kind: HUDKind) -> HUDLook {
        let key = "hud.\(kind.rawValue)."
        let legacy = store.string(forKey: "hud.style")
        let labels = load("hud.showLabels", true)
        let style = HUDProgressStyle(rawValue: store.string(forKey: key + "style") ?? "")
            ?? (kind == .volume ? (legacy == "decibels" ? .decibel : .white) : (legacyGlow ? .glow : .white))
        return HUDLook(
            style: style.fits(kind) ? style : .white,
            showPercentage: load(key + "showPercentage", legacy == "percentage" || labels),
            labels: load(key + "labels", labels),
            duration: load(key + "duration", load("hud.duration", 1.5)),
            speed: AnimationSpeed(rawValue: store.string(forKey: key + "speed") ?? legacySpeed) ?? .smooth
        )
    }

    /// "hud.glow" was on unless turned off, so it is settled on the first launch that reads it: an
    /// install from before (onboarded) keeps the glow, a new one starts White.
    private static var legacyGlow: Bool {
        if store.object(forKey: "hud.glow") == nil { store.set(store.bool(forKey: "onboarded"), forKey: "hud.glow") }
        return store.bool(forKey: "hud.glow")
    }

    /// The island's speed, settled as "hud.speed" on the first launch that reads it: a HUD never set
    /// keeps it, whatever the island's speed does later. Not a synced key, so settling it never
    /// overrides another Mac.
    private static var legacySpeed: String {
        if store.object(forKey: "hud.speed") == nil { store.set(store.string(forKey: "speed") ?? AnimationSpeed.smooth.rawValue, forKey: "hud.speed") }
        return store.string(forKey: "hud.speed") ?? ""
    }

    func save(_ kind: HUDKind) {
        let key = "hud.\(kind.rawValue)."
        store.set(style.rawValue, forKey: key + "style")
        store.set(showPercentage, forKey: key + "showPercentage")
        store.set(labels, forKey: key + "labels")
        store.set(duration, forKey: key + "duration")
        store.set(speed.rawValue, forKey: key + "speed")
    }
}

/// An output device as the HUD presents it.
struct HUDOutput: Equatable {
    var name: String
    var transport: UInt32
    var dataSource: UInt32?
    /// Symbol of the Bluetooth device Isola recognised by product ID (renamed AirPods too).
    var deviceSymbol: String?
    /// That device's colour (an AirPods Max finish), tinting the glyph.
    var deviceTint: NSColor?
    /// CoreAudio model UID.
    var model: String?

    /// Device glyph, or nil for plain speakers (drawn as level-aware speaker waves).
    var symbol: String? {
        if let deviceSymbol { return deviceSymbol }
        let n = name.lowercased()
        if n.contains("airpods pro 3") { return DeviceSymbol.resolve("airpods.pro.gen3", fallback: "airpodspro") }
        if n.contains("earpods") { return "earpods" }
        // Studio Display, LG UltraFine "Display Audio" (USB); HDMI/DisplayPort monitors keep the tv glyph below.
        if n.contains("display"), transport != kAudioDeviceTransportTypeHDMI, transport != kAudioDeviceTransportTypeDisplayPort { return "display" }
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

    init(name: String, transport: UInt32, dataSource: UInt32? = nil, deviceSymbol: String? = nil, deviceTint: NSColor? = nil, model: String? = nil) {
        self.name = name
        self.transport = transport
        self.dataSource = dataSource
        self.deviceSymbol = deviceSymbol
        self.deviceTint = deviceTint
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
    /// In-island volume controls set this so their own changes don't pop the HUD over them.
    static var quietUntil = Date.distantPast

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

    // MARK: Showing

    /// Each HUD reads its own look: labels, how long it stays and how fast it springs.
    static func item(_ kind: HUDKind) -> IslandItem {
        let item = IslandItem(id: "hud.\(kind.rawValue)", kind: .hud) {
            LiveHUD(part: .leading)
        } trailing: {
            LiveHUD(part: .trailing)
        }
        return HUDPreferences.shared.look(kind).labels ? item.peek(always: true) { LiveHUD(part: .label) } : item
    }

    static func show(_ snapshot: HUDSnapshot) {
        HUDModel.shared.snapshot = snapshot
        let look = HUDPreferences.shared.look(snapshot.kind)
        Island.shared.post(item(snapshot.kind), duration: look.duration, animation: look.motion, collapse: look.collapse)
    }

    /// Passive path: any volume/mute change on the output device.
    private static func volumeChanged() {
        guard let level = SystemAudio.volume() else { return }
        let muted = SystemAudio.isMuted()
        defer { lastVolume = (level, muted) }
        guard ready, Date() > quietUntil, let last = lastVolume, abs(last.level - level) > 0.001 || last.muted != muted, syncsExternalChanges else { return }
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

    /// Pushing past 0% or 100% stretches the bar toward the push and lets it spring back (at the
    /// HUD's speed), only with the island's Overshoot on.
    private static func rubberBand() {
        guard Preferences.shared.overshoot else { return }
        let spring = HUDPreferences.shared.look(HUDModel.shared.snapshot.kind).spring(300, 9)
        withAnimation(.easeOut(duration: 0.08)) { HUDModel.shared.stretch = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(spring) { HUDModel.shared.stretch = 0 }
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
            var output = args["device"].map(HUDOutput.preset) ?? HUDOutput.preset("speakers")
            // A device of that name from `system.bluetooth color=…` lends its colour, as a real one does.
            output.deviceTint = DevicesState.shared.devices.first { $0.name == output.name }?.tint
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
        // A settings edit as the HUDs page makes it (Link applies): `hud.pref kind=brightness style=glow
        // percent=1 labels=0 speed=fast duration=3`; `linked=0|1`, `output=symbol|device`. `hud.state` reads both looks.
        Debug.on("hud.pref") { args in
            let hud = HUDPreferences.shared
            let kind = args["kind"].flatMap(HUDKind.init(rawValue:)) ?? .volume
            if let v = args["linked"] { if v == "1" { hud.link(from: kind) } else { hud.linked = false } }
            if let v = args["style"].flatMap(HUDProgressStyle.init(rawValue:)) { hud.edit(kind, \.style, v) }
            if let v = args["percent"] { hud.edit(kind, \.showPercentage, v == "1") }
            if let v = args["labels"] { hud.edit(kind, \.labels, v == "1") }
            if let v = args["speed"].flatMap(AnimationSpeed.init(rawValue:)) { hud.edit(kind, \.speed, v) }
            if let v = args["duration"].flatMap(Double.init) { hud.edit(kind, \.duration, v) }
            if let v = args["output"].flatMap(HUDOutputStyle.init(rawValue:)) { hud.outputStyle = v }
        }
        Debug.on("hud.state") { _ in
            let hud = HUDPreferences.shared
            func describe(_ l: HUDLook) -> String { "\(l.style.rawValue) percent=\(l.showPercentage) labels=\(l.labels) speed=\(l.speed.rawValue) duration=\(l.duration)" }
            Debug.reply("linked=\(hud.linked) output=\(hud.outputStyle.rawValue) | sound: \(describe(hud.look(.volume))) | display: \(describe(hud.look(.brightness)))")
        }
    }

    /// Pure-logic checks; run with every gallery render (debug build asserts).
    static func selfCheck() {
        // Link: an edit lands on both HUDs, except a style only one of them has; unlinked, on one.
        let pair = (volume: HUDLook(), brightness: HUDLook(style: .glow))
        var r = HUDPreferences.edit(pair, .volume, \.style, .accent, linked: true)
        precondition(r.volume.style == .accent && r.brightness.style == .accent, "linked edit reaches both HUDs")
        r = HUDPreferences.edit(pair, .volume, \.style, .decibel, linked: true)
        precondition(r.volume.style == .decibel && r.brightness.style == .glow, "decibels stay with the Sound HUD")
        r = HUDPreferences.edit(pair, .brightness, \.labels, false, linked: true)
        precondition(!r.volume.labels && !r.brightness.labels && r.brightness.style == .glow, "other settings follow, styles stay")
        r = HUDPreferences.edit(pair, .brightness, \.speed, .instant, linked: false)
        precondition(r.volume.speed == .smooth && r.brightness.speed == .instant, "unlinked: one HUD")
        // The narrow wing is never blank: the number (the percentage by default) or, without one, a bar;
        // muted, "Mute" wherever a number would show, unless the label row already says "Muted".
        typealias W = HUDPart.Wing
        precondition(HUDLook().showPercentage && HUDPart.wing(labels: true, showPercentage: true, decibels: false, silent: false) == W.percent
            && HUDPart.wing(labels: true, showPercentage: false, decibels: false, silent: false) == W.bar
            && HUDPart.wing(labels: true, showPercentage: true, decibels: false, silent: true) == W.percent
            && HUDPart.wing(labels: true, showPercentage: false, decibels: true, silent: false) == W.decibels
            && HUDPart.wing(labels: false, showPercentage: false, decibels: false, silent: false) == W.bar
            && HUDPart.wing(labels: false, showPercentage: true, decibels: false, silent: false) == W.percent
            && HUDPart.wing(labels: false, showPercentage: true, decibels: true, silent: false) == W.decibels
            && HUDPart.wing(labels: false, showPercentage: true, decibels: false, silent: true) == W.mute
            && HUDPart.wing(labels: false, showPercentage: false, decibels: false, silent: true) == W.bar, "HUD wing")
        precondition(!HUDProgressStyle.glow.fits(.volume) && !HUDProgressStyle.decibel.fits(.brightness) && HUDProgressStyle.stylized.fits(.volume), "styles per HUD")
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
        func brightness(_ level: Double) -> HUDSnapshot { HUDSnapshot(kind: .brightness, level: level) }
        let compact = HUDLook(showPercentage: false, labels: false)
        add("volume-low", volume(0.19))
        add("volume-mid", volume(0.5))
        add("volume-high", volume(0.94))
        add("volume-muted", volume(0.5, muted: true))
        add("volume-airpodspro", volume(0.62, device: "airpodspro"))
        add("volume-airpodsmax-notch", volume(0.4, device: "airpodsmax"), geometry: .notchPreview)
        var blue = volume(0.4, device: "airpodsmax")
        blue.output.deviceTint = BluetoothMonitor.maxColors[0x03]?.tint
        add("volume-airpodsmax-blue", blue)
        add("volume-notch", volume(0.5), geometry: .notchPreview)
        // Show percentage off: a compact bar holds the wing (the row below keeps its own).
        add("volume-bar", volume(0.62), HUDLook(showPercentage: false))
        add("volume-bar-notch", volume(0.62, device: "airpodspro"), HUDLook(showPercentage: false), geometry: .notchPreview)
        add("volume-bar-muted", volume(0.5, muted: true), HUDLook(showPercentage: false))
        add("style-white-compact", volume(0.5), compact)
        add("style-white-compact-notch", volume(0.5), compact, geometry: .notchPreview)
        add("style-percent-compact", volume(0.75), HUDLook(showPercentage: true, labels: false))
        add("style-percent-muted", volume(0.5, muted: true), HUDLook(showPercentage: true, labels: false))
        add("style-decibel-compact", volume(0.5), HUDLook(style: .decibel, labels: false))
        add("style-decibel-labels", volume(0.5), HUDLook(style: .decibel))
        add("style-accent-compact", volume(0.5), HUDLook(style: .accent, showPercentage: false, labels: false))
        add("style-accent-labels", volume(0.66), HUDLook(style: .accent, showPercentage: true))
        add("style-stylized-compact", volume(0.7), HUDLook(style: .stylized, showPercentage: false, labels: false))
        add("style-stylized-airpodsmax-blue", blue, HUDLook(style: .stylized))
        // Output device › Show speaker symbol: AirPods read as the speaker and "Volume".
        add("output-symbol", volume(0.62, device: "airpodspro"), HUDLook(output: .symbol))
        add("brightness-white", brightness(0.8))
        add("brightness-glow", brightness(0.8), HUDLook(style: .glow))
        add("brightness-glow-compact", brightness(0.6), HUDLook(style: .glow, showPercentage: false, labels: false))
        add("brightness-stylized", brightness(0.7), HUDLook(style: .stylized, showPercentage: true))
        add("brightness-accent-compact-notch", brightness(0.45), HUDLook(style: .accent, showPercentage: false, labels: false), geometry: .notchPreview)
        add("brightness-low", brightness(0.2), HUDLook(style: .glow))
        add("brightness-display-symbol", brightness(0.55), HUDLook(displaySymbol: true))
        add("brightness-compact-notch", brightness(0.7), compact, geometry: .notchPreview)
        // Peak of the rubber band when pushing past the ends.
        add("overshoot-volume-max", volume(1), stretch: 1)
        add("overshoot-volume-min-compact", volume(0), compact, stretch: 1)
        add("overshoot-brightness-max-compact-notch", brightness(1), compact, geometry: .notchPreview, stretch: 1)
        snapshotSettings("hud-settings", page: .volume)
        snapshotSettings("hud-settings-display", page: .brightness)
    }

    /// Forms are AppKit-backed, which ImageRenderer can't draw: render the settings page
    /// through an offscreen hosting view into the gallery folder instead.
    private static func snapshotSettings(_ name: String, page: HUDKind) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--gallery"), i + 1 < args.count else { return }
        HUDPreferences.shared.page = page
        defer { HUDPreferences.shared.page = .volume }
        let size = NSRect(x: 0, y: 0, width: 520, height: 1240)
        let host = NSHostingView(rootView: HUDSettingsView().frame(width: size.width, height: size.height))
        host.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size.size
        host.cacheDisplay(in: size, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]).appendingPathComponent("\(name).png"))
    }
}
