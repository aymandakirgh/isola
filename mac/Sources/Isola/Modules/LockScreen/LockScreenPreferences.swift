import SwiftUI
import Observation

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: "lockscreen.\(key)") as? T ?? fallback }
private func save(_ key: String, _ value: Any) { store.set(value, forKey: "lockscreen.\(key)") }

enum NowPlayingWidgetStyle: String, CaseIterable, Identifiable {
    case glass, frosted, dark, artwork, clear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Glass"
        case .frosted: "Frosted"
        case .dark: "Dark"
        case .artwork: "Artwork"
        case .clear: "Clear"
        }
    }

    /// The styles to pick from. Glass is Liquid Glass, new in macOS 26: before it, Glass would draw
    /// what Frosted draws.
    static let offered: [NowPlayingWidgetStyle] = if #available(macOS 26, *) { allCases } else { allCases.filter { $0 != .glass } }

    /// As this Mac draws it: a Glass (the default, or one from a Mac on macOS 26) is Frosted before macOS 26.
    var drawn: NowPlayingWidgetStyle { Self.offered.contains(self) ? self : .frosted }
}

enum WeatherWidgetStyle: String, CaseIterable, Identifiable {
    case conditions, precipitation, sun, compact
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conditions: "Conditions"
        case .precipitation: "Precipitation"
        case .sun: "Sunrise & Sunset"
        case .compact: "Temperature only"
        }
    }

    /// A stored value. "detailed", from before these styles, led with the rain outlook.
    init(stored raw: String) {
        self = raw == "detailed" ? .precipitation : WeatherWidgetStyle(rawValue: raw) ?? .conditions
    }
}

/// Lock Screen settings, persisted under `lockscreen.*` in user defaults.
@MainActor @Observable
final class LockScreenPreferences {
    static let shared = LockScreenPreferences()

    var enabled: Bool = load("enabled", true) { didSet { save("enabled", enabled); LockScreenController.shared.refresh() } }
    var showNowPlaying: Bool = load("showNowPlaying", true) { didSet { save("showNowPlaying", showNowPlaying) } }
    var showFocus: Bool = load("showFocus", true) { didSet { save("showFocus", showFocus) } }
    var showWeather: Bool = load("showWeather", true) { didSet { save("showWeather", showWeather) } }
    var showBattery: Bool = load("showBattery", true) { didSet { save("showBattery", showBattery) } }
    var showConnectivity: Bool = load("showConnectivity", true) { didSet { save("showConnectivity", showConnectivity) } }
    var showCalendar: Bool = load("showCalendar", true) { didSet { save("showCalendar", showCalendar) } }
    /// As picked, here or on another Mac, and stored (and synced) as it is.
    private var pickedNowPlayingStyle: NowPlayingWidgetStyle = NowPlayingWidgetStyle(rawValue: load("nowPlayingStyle", "glass")) ?? .glass {
        didSet { save("nowPlayingStyle", pickedNowPlayingStyle.rawValue) }
    }
    /// What the Lock Screen draws and the picker shows: before macOS 26 a Glass reads as Frosted.
    var nowPlayingStyle: NowPlayingWidgetStyle {
        get { pickedNowPlayingStyle.drawn }
        set { pickedNowPlayingStyle = newValue }
    }
    var weatherStyle: WeatherWidgetStyle = WeatherWidgetStyle(stored: load("weatherStyle", "conditions")) {
        didSet { save("weatherStyle", weatherStyle.rawValue) }
    }
    /// Points the Now Playing widget moves down (+) or up (−) from its default spot.
    var nowPlayingOffset: Double = load("nowPlayingOffset", 0) { didSet { save("nowPlayingOffset", nowPlayingOffset) } }
    /// Hide the Now Playing widget once playback stops…
    var hideWhileInactive: Bool = load("hideWhileInactive", false) { didSet { save("hideWhileInactive", hideWhileInactive) } }
    /// …immediately, instead of after a short grace period.
    var hideInstantly: Bool = load("hideInstantly", false) { didSet { save("hideInstantly", hideInstantly) } }
    var showVolumeControl: Bool = load("showVolumeControl", false) { didSet { save("showVolumeControl", showVolumeControl) } }
    var keepAwake: Bool = load("keepAwake", false) { didSet { save("keepAwake", keepAwake); LockScreenController.shared.refresh() } }
    var showOnScreensaver: Bool = load("showOnScreensaver", false) { didSet { save("showOnScreensaver", showOnScreensaver); LockScreenController.shared.refresh() } }

    /// `isolactl pref.lockscreen key=value` (booleans take 1/0).
    func set(_ key: String, _ value: String) {
        let on = value == "1" || value == "true"
        switch key {
        case "enabled": enabled = on
        case "showNowPlaying": showNowPlaying = on
        case "showFocus": showFocus = on
        case "showWeather": showWeather = on
        case "showBattery": showBattery = on
        case "showConnectivity": showConnectivity = on
        case "showCalendar": showCalendar = on
        case "nowPlayingStyle": nowPlayingStyle = NowPlayingWidgetStyle(rawValue: value) ?? .glass
        case "weatherStyle": weatherStyle = WeatherWidgetStyle(stored: value)
        case "nowPlayingOffset": nowPlayingOffset = Double(value) ?? 0
        case "hideWhileInactive": hideWhileInactive = on
        case "hideInstantly": hideInstantly = on
        case "showVolumeControl": showVolumeControl = on
        case "keepAwake": keepAwake = on
        case "showOnScreensaver": showOnScreensaver = on
        default: NSLog("isola: unknown lockscreen pref %@", key)
        }
    }
}

struct LockScreenSettingsView: View {
    @Bindable var prefs = LockScreenPreferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show widgets on the Lock Screen", isOn: $prefs.enabled)
                Toggle("Keep the Mac awake while locked", isOn: $prefs.keepAwake)
                Toggle("Also show over the screen saver", isOn: $prefs.showOnScreensaver)
            } footer: {
                if !LockScreenSpace.available {
                    Text("This version of macOS doesn't allow windows on the Lock Screen, so widgets stay off.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Widgets") {
                Toggle("Now Playing", isOn: $prefs.showNowPlaying)
                Toggle("Focus", isOn: $prefs.showFocus)
                Toggle("Weather", isOn: $prefs.showWeather)
                Toggle("Battery", isOn: $prefs.showBattery)
                Toggle("Connectivity", isOn: $prefs.showConnectivity)
                Toggle("Calendar", isOn: $prefs.showCalendar)
            }
            Section("Now Playing") {
                Picker("Style", selection: $prefs.nowPlayingStyle) {
                    ForEach(NowPlayingWidgetStyle.offered) { Text($0.title).tag($0) }
                }
                Toggle("Show volume control", isOn: $prefs.showVolumeControl)
                Toggle("Hide while nothing is playing", isOn: $prefs.hideWhileInactive)
                Toggle("Hide instantly", isOn: $prefs.hideInstantly).disabled(!prefs.hideWhileInactive)
                LabeledContent("Vertical offset") {
                    Slider(value: $prefs.nowPlayingOffset, in: -120...120)
                }
            }
            Section("Weather") {
                Picker("Style", selection: $prefs.weatherStyle) {
                    ForEach(WeatherWidgetStyle.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
