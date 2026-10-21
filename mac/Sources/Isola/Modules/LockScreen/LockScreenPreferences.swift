import SwiftUI
import Observation

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: "lockscreen.\(key)") as? T ?? fallback }
private func save(_ key: String, _ value: Any) { store.set(value, forKey: "lockscreen.\(key)") }

enum NowPlayingWidgetStyle: String, CaseIterable, Identifiable {
    case glass, dark, artwork, clear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Glass"
        case .dark: "Dark"
        case .artwork: "Artwork"
        case .clear: "Clear"
        }
    }
}

enum WeatherWidgetStyle: String, CaseIterable, Identifiable {
    case compact, detailed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    var nowPlayingStyle: NowPlayingWidgetStyle = NowPlayingWidgetStyle(rawValue: load("nowPlayingStyle", "glass")) ?? .glass {
        didSet { save("nowPlayingStyle", nowPlayingStyle.rawValue) }
    }
    var weatherStyle: WeatherWidgetStyle = WeatherWidgetStyle(rawValue: load("weatherStyle", "compact")) ?? .compact {
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
        case "weatherStyle": weatherStyle = WeatherWidgetStyle(rawValue: value) ?? .compact
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
                    ForEach(NowPlayingWidgetStyle.allCases) { Text($0.title).tag($0) }
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
