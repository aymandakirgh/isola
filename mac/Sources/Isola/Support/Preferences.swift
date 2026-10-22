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

/// Island › Idle Activity: what the island opens with nothing running (`duo` is the player and
/// the calendar side by side, not Duo mode's bubble).
enum IdleActivity: String, CaseIterable, Identifiable {
    case none, calendar, nowPlaying, duo, mostRecent
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
    /// Off: the open panel and scrolling titles are cut at the island's edge instead of blurring into it.
    var progressiveBlur: Bool = load("progressiveBlur", true) { didSet { store.set(progressiveBlur, forKey: "progressiveBlur") } }
    /// Hidden, Isola is reached by opening it again from Finder or Spotlight (it shows Settings).
    var hideMenuBarIcon: Bool = load("hideMenuBarIcon", false) { didSet { store.set(hideMenuBarIcon, forKey: "hideMenuBarIcon"); StatusItem.shared.syncVisibility() } }

    // Behaviour
    /// Seconds of hovering before the island expands; 0 disables expand-on-hover.
    var hoverExpandDelay: Double = load("hoverExpandDelay", 0) { didSet { store.set(hoverExpandDelay, forKey: "hoverExpandDelay") } }
    /// Off: clicking or hovering an inactive activity (paused media) doesn't open its panel.
    var expandWhileInactive: Bool = load("expandWhileInactive", true) { didSet { store.set(expandWhileInactive, forKey: "expandWhileInactive") } }
    /// With two or more live activities, the next one sits in a bubble beside the island.
    var duo: Bool = load("duo", false) { didSet { store.set(duo, forKey: "duo") } }
    var notificationDuration: Double = load("notificationDuration", 3.5) { didSet { store.set(notificationDuration, forKey: "notificationDuration") } }
    /// A trackpad tap as the island lifts, opens, closes and takes a swipe.
    var haptics: Bool = load("haptics", true) { didSet { store.set(haptics, forKey: "haptics") } }
    /// The system accent colour, instead of white, for hover, press and the Compact and Contrast outlines.
    var useAccentColor: Bool = load("useAccentColor", false) { didSet { store.set(useAccentColor, forKey: "useAccentColor") } }
    /// With nothing running, a click, hover-expand or swipe down opens this (Island › Idle Activity)…
    var idleActivity: IdleActivity = loadEnum("idleActivity", .none) { didSet { store.set(idleActivity.rawValue, forKey: "idleActivity") } }
    /// …which also stays in the compact island, the notchless pill included.
    var forceIdleActivity: Bool = load("forceIdleActivity", false) { didSet { store.set(forceIdleActivity, forKey: "forceIdleActivity") } }

    // Gestures
    /// Swipes follow content direction (like scrolling) rather than finger direction.
    var naturalSwipe: Bool = load("naturalSwipe", false) { didSet { store.set(naturalSwipe, forKey: "naturalSwipe") } }
    /// Swipe down opens the island, swipe up closes it.
    var swipeToToggle: Bool = load("swipeToToggle", true) { didSet { store.set(swipeToToggle, forKey: "swipeToToggle") } }
    /// Horizontal swipes skip tracks.
    var swipeToSkip: Bool = load("swipeToSkip", true) { didSet { store.set(swipeToSkip, forKey: "swipeToSkip") } }
    /// Swipe up hides a compact live activity until its content changes.
    var swipeToDismiss: Bool = load("swipeToDismiss", true) { didSet { store.set(swipeToDismiss, forKey: "swipeToDismiss") } }
    /// Swipe down on the open island shows the next activity (middle click always does).
    var swipeToCycle: Bool = load("swipeToCycle", true) { didSet { store.set(swipeToCycle, forKey: "swipeToCycle") } }

    var speed: AnimationSpeed = loadEnum("speed", .smooth) { didSet { store.set(speed.rawValue, forKey: "speed") } }
    var overshoot: Bool = load("overshoot", true) { didSet { store.set(overshoot, forKey: "overshoot") } }
    var unlockSound: Bool = load("unlockSound", true) { didSet { store.set(unlockSound, forKey: "unlockSound"); if unlockSound { Sounds.unlock() } } }
    var lockSound: Bool = load("lockSound", false) { didSet { store.set(lockSound, forKey: "lockSound"); if lockSound { Sounds.lock() } } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    private func displaysChanged() {
        IslandWindows.shared.refresh()
    }

    /// Debug/CLI access by key name.
    func set(_ key: String, _ value: String) {
        let on = value == "1" || value == "true"
        switch key {
        case "progressiveBlur": progressiveBlur = on
        case "hideMenuBarIcon": hideMenuBarIcon = on
        case "haptics": haptics = on
        case "useAccentColor": useAccentColor = on
        case "idleActivity": idleActivity = IdleActivity(rawValue: value) ?? .none
        case "forceIdleActivity": forceIdleActivity = on
        case "swipeToToggle": swipeToToggle = on
        case "swipeToSkip": swipeToSkip = on
        case "swipeToDismiss": swipeToDismiss = on
        case "swipeToCycle": swipeToCycle = on
        case "allDisplays": allDisplays = on
        case "preferredDisplay": preferredDisplay = value
        case "simulatedNotch": simulatedNotch = on
        case "showIdlePill": showIdlePill = on
        case "heightTweak": heightTweak = Double(value) ?? 0
        case "widthTweak": widthTweak = Double(value) ?? 0
        case "hoverExpandDelay": hoverExpandDelay = Double(value) ?? 0
        case "expandWhileInactive": expandWhileInactive = on
        case "duo": duo = on
        case "notificationDuration": notificationDuration = Double(value) ?? 3.5
        case "naturalSwipe": naturalSwipe = on
        case "speed": speed = AnimationSpeed(rawValue: value) ?? .smooth
        case "overshoot": overshoot = on
        case "outline": outline = OutlineStyle(rawValue: value) ?? .none
        case "hideFromScreenCapture": hideFromScreenCapture = on
        default: break
        }
    }
}
