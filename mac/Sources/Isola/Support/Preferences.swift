import Foundation
import Observation
import ServiceManagement

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }
private func loadEnum<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
    (store.string(forKey: key)).flatMap(T.init(rawValue:)) ?? fallback
}

enum OutlineStyle: String, CaseIterable, Identifiable {
    case none, contrast, colored, compact
    var id: String { rawValue }
}

/// App-wide settings (island, display, behaviour). Feature modules keep their own
/// settings next to their code using the same pattern.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    // Displays
    var allDisplays: Bool = load("allDisplays", false) { didSet { store.set(allDisplays, forKey: "allDisplays"); displaysChanged() } }
    /// "auto" (notch screen, else main), "main", "builtin", or a screen's localized name.
    var preferredDisplay: String = load("preferredDisplay", "auto") { didSet { store.set(preferredDisplay, forKey: "preferredDisplay"); displaysChanged() } }
    /// On notchless displays: draw a notch flush with the top edge instead of a floating pill.
    var simulatedNotch: Bool = load("simulatedNotch", false) { didSet { store.set(simulatedNotch, forKey: "simulatedNotch"); displaysChanged() } }
    /// Keep the pill visible on notchless displays even with nothing to show.
    var showIdlePill: Bool = load("showIdlePill", false) { didSet { store.set(showIdlePill, forKey: "showIdlePill") } }
    var heightTweak: Double = load("heightTweak", 0) { didSet { store.set(heightTweak, forKey: "heightTweak"); displaysChanged() } }
    var widthTweak: Double = load("widthTweak", 0) { didSet { store.set(widthTweak, forKey: "widthTweak"); displaysChanged() } }
    var hideInFullscreen: Bool = load("hideInFullscreen", true) { didSet { store.set(hideInFullscreen, forKey: "hideInFullscreen") } }
    var hideWhileGaming: Bool = load("hideWhileGaming", true) { didSet { store.set(hideWhileGaming, forKey: "hideWhileGaming") } }
    var hideInMissionControl: Bool = load("hideInMissionControl", true) { didSet { store.set(hideInMissionControl, forKey: "hideInMissionControl") } }
    var hideFromScreenCapture: Bool = load("hideFromScreenCapture", false) {
        didSet { store.set(hideFromScreenCapture, forKey: "hideFromScreenCapture"); displaysChanged() }
    }
    var outline: OutlineStyle = loadEnum("outline", .none) { didSet { store.set(outline.rawValue, forKey: "outline") } }

    // Behaviour
    /// Seconds of hovering before the island expands; 0 disables expand-on-hover.
    var hoverExpandDelay: Double = load("hoverExpandDelay", 0) { didSet { store.set(hoverExpandDelay, forKey: "hoverExpandDelay") } }
    var notificationDuration: Double = load("notificationDuration", 3.5) { didSet { store.set(notificationDuration, forKey: "notificationDuration") } }
    /// Swipes follow content direction (like scrolling) rather than finger direction.
    var naturalSwipe: Bool = load("naturalSwipe", false) { didSet { store.set(naturalSwipe, forKey: "naturalSwipe") } }
    var speed: AnimationSpeed = loadEnum("speed", .smooth) { didSet { store.set(speed.rawValue, forKey: "speed") } }
    var overshoot: Bool = load("overshoot", true) { didSet { store.set(overshoot, forKey: "overshoot") } }
    var unlockSound: Bool = load("unlockSound", true) { didSet { store.set(unlockSound, forKey: "unlockSound") } }
    var lockSound: Bool = load("lockSound", false) { didSet { store.set(lockSound, forKey: "lockSound") } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    private func displaysChanged() {
        IslandWindows.shared.refresh()
    }

    /// Debug/CLI access by key name.
    func set(_ key: String, _ value: String) {
        switch key {
        case "allDisplays": allDisplays = value == "1" || value == "true"
        case "preferredDisplay": preferredDisplay = value
        case "simulatedNotch": simulatedNotch = value == "1" || value == "true"
        case "showIdlePill": showIdlePill = value == "1" || value == "true"
        case "heightTweak": heightTweak = Double(value) ?? 0
        case "widthTweak": widthTweak = Double(value) ?? 0
        case "hoverExpandDelay": hoverExpandDelay = Double(value) ?? 0
        case "notificationDuration": notificationDuration = Double(value) ?? 3.5
        case "naturalSwipe": naturalSwipe = value == "1" || value == "true"
        case "speed": speed = AnimationSpeed(rawValue: value) ?? .smooth
        case "overshoot": overshoot = value == "1" || value == "true"
        case "outline": outline = OutlineStyle(rawValue: value) ?? .none
        case "hideFromScreenCapture": hideFromScreenCapture = value == "1" || value == "true"
        default: break
        }
    }
}
