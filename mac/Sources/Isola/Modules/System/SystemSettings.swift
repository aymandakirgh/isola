import Observation
import SwiftUI

private let store = UserDefaults.standard
private func flag(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }

/// How a connecting device is pictured: the looping earbuds clip where there is one, or always its SF Symbol.
enum DeviceImage: String, CaseIterable, Identifiable {
    case model, symbol
    var id: String { rawValue }
    var title: String { self == .model ? "3D models" : "Symbols" }
}

/// Settings for system-driven notifications and live activities. Turning a sound on
/// plays it once as a preview.
@MainActor @Observable
final class SystemPreferences {
    static let shared = SystemPreferences()

    // Battery
    var chargingNotification = flag("system.chargingNotification", true) {
        didSet { store.set(chargingNotification, forKey: "system.chargingNotification") }
    }
    var chargingActivity = flag("system.chargingActivity", false) {
        didSet { store.set(chargingActivity, forKey: "system.chargingActivity"); PowerMonitor.shared.syncActivity() }
    }
    /// The charger and low-battery notifications draw a ring instead of the number; the charging peek leaves it out.
    var hideBatteryPercentage = flag("system.hideBatteryPercentage", false) {
        didSet { store.set(hideBatteryPercentage, forKey: "system.hideBatteryPercentage") }
    }
    var lowBatteryNotification = flag("system.lowBatteryNotification", true) {
        didSet { store.set(lowBatteryNotification, forKey: "system.lowBatteryNotification") }
    }
    /// First warning level (0...1); a second, critical warning always fires at 10%.
    var lowBatteryThreshold = store.object(forKey: "system.lowBatteryThreshold") as? Double ?? 0.2 {
        didSet { store.set(lowBatteryThreshold, forKey: "system.lowBatteryThreshold") }
    }
    var lowBatterySound = flag("system.lowBatterySound", true) {
        didSet { store.set(lowBatterySound, forKey: "system.lowBatterySound"); if lowBatterySound { Sounds.lowBattery() } }
    }
    var lowPowerNotification = flag("system.lowPowerNotification", true) {
        didSet { store.set(lowPowerNotification, forKey: "system.lowPowerNotification") }
    }

    // Connectivity
    var bluetoothNotification = flag("system.bluetoothNotification", true) {
        didSet { store.set(bluetoothNotification, forKey: "system.bluetoothNotification") }
    }
    /// Announce keyboards, mice and other non-audio devices too.
    var bluetoothAllDevices = flag("system.bluetoothAllDevices", false) {
        didSet { store.set(bluetoothAllDevices, forKey: "system.bluetoothAllDevices") }
    }
    var deviceImage = DeviceImage(rawValue: store.string(forKey: "system.deviceImage") ?? "") ?? .model {
        didSet { store.set(deviceImage.rawValue, forKey: "system.deviceImage") }
    }
    var deviceLowBattery = flag("system.deviceLowBattery", true) {
        didSet { store.set(deviceLowBattery, forKey: "system.deviceLowBattery") }
    }
    /// Devices' own first warning level (0...1); their second one fires at 10% too.
    var deviceLowBatteryThreshold = store.object(forKey: "system.deviceLowBatteryThreshold") as? Double ?? 0.2 {
        didSet { store.set(deviceLowBatteryThreshold, forKey: "system.deviceLowBatteryThreshold") }
    }
    var deviceLowBatterySound = flag("system.deviceLowBatterySound", true) {
        didSet { store.set(deviceLowBatterySound, forKey: "system.deviceLowBatterySound"); if deviceLowBatterySound { Sounds.lowBattery() } }
    }

    // Focus
    var focusNotification = flag("system.focusNotification", true) {
        didSet { store.set(focusNotification, forKey: "system.focusNotification") }
    }
    /// Focus mode ids whose changes stay out of the island.
    var focusMutedModes: [String] = store.stringArray(forKey: "system.focusMutedModes") ?? [] {
        didSet { store.set(focusMutedModes, forKey: "system.focusMutedModes") }
    }
    /// Modes the Focus database named that Isola doesn't know by id (custom ones): id → [name, symbol].
    var focusSeenModes: [String: [String]] = store.dictionary(forKey: "system.focusSeenModes") as? [String: [String]] ?? [:] {
        didSet { store.set(focusSeenModes, forKey: "system.focusSeenModes") }
    }
    var focusActivity = flag("system.focusActivity", false) {
        didSet { store.set(focusActivity, forKey: "system.focusActivity"); FocusMonitor.shared.syncActivity() }
    }
    /// A soft sound when the Sleep Focus turns on (telling Sleep apart needs Full Disk Access).
    var sleepFocusSound = flag("system.sleepFocusSound", false) {
        didSet { store.set(sleepFocusSound, forKey: "system.sleepFocusSound"); if sleepFocusSound { Sounds.sleepFocus() } }
    }

    // Lock
    var lockActivity = flag("system.lockActivity", true) {
        didSet { store.set(lockActivity, forKey: "system.lockActivity") }
    }
}

struct SystemSettingsView: View {
    @Bindable var prefs = SystemPreferences.shared
    @Bindable var core = Preferences.shared

    var body: some View {
        Form {
            Section("Battery") {
                Toggle("Charger connected and disconnected", isOn: $prefs.chargingNotification)
                Toggle("Charging live activity", isOn: $prefs.chargingActivity)
                Toggle("Hide percentage", isOn: $prefs.hideBatteryPercentage)
                Toggle("Low battery warning", isOn: $prefs.lowBatteryNotification)
                warnAt($prefs.lowBatteryThreshold).disabled(!prefs.lowBatteryNotification)
                Toggle("Low battery sound", isOn: $prefs.lowBatterySound)
                    .disabled(!prefs.lowBatteryNotification)
                Toggle("Low Power Mode", isOn: $prefs.lowPowerNotification)
            }
            Section("Connectivity") {
                Toggle("Device connected and disconnected", isOn: $prefs.bluetoothNotification)
                Toggle("Include keyboards, mice and other devices", isOn: $prefs.bluetoothAllDevices)
                Picker("Device image", selection: $prefs.deviceImage) {
                    ForEach(DeviceImage.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Low battery warning for devices", isOn: $prefs.deviceLowBattery)
                warnAt($prefs.deviceLowBatteryThreshold).disabled(!prefs.deviceLowBattery)
                Toggle("Low battery sound for devices", isOn: $prefs.deviceLowBatterySound)
                    .disabled(!prefs.deviceLowBattery)
                PermissionRow(permission: Permission.bluetooth)
            }
            Section {
                Toggle("Focus changes", isOn: $prefs.focusNotification)
                Toggle("Focus live activity", isOn: $prefs.focusActivity)
                Toggle("Sound when Sleep turns on", isOn: $prefs.sleepFocusSound)
                PermissionRow(permission: Permission.focus)
                PermissionRow(permission: Permission.fullDiskAccess)
            } header: {
                Text("Focus")
            } footer: {
                note("Without Full Disk Access, Isola can only tell that a Focus is on, not which one.")
            }
            Section {
                ForEach(FocusMonitor.listed(seen: prefs.focusSeenModes)) { mode in
                    Toggle(isOn: allowed(mode.id)) {
                        Label {
                            Text(mode.title)
                        } icon: {
                            Image(systemName: DeviceSymbol.resolve(mode.symbol, fallback: "moon.fill")).foregroundStyle(Color(nsColor: mode.tint))
                        }
                    }
                }
            } header: {
                Text("Allowed Notifications")
            } footer: {
                note("Modes switched off here change quietly. Custom modes join the list once Isola has seen them on.")
            }
            .disabled(!prefs.focusNotification)
            Section("Lock") {
                Toggle("Lock live activity", isOn: $prefs.lockActivity)
                Toggle("Sound on unlock", isOn: $core.unlockSound)
                Toggle("Sound on lock", isOn: $core.lockSound)
            }
        }
        .formStyle(.grouped)
    }

    private func warnAt(_ threshold: Binding<Double>) -> some View {
        Picker("Warn at", selection: threshold) {
            ForEach([0.1, 0.15, 0.2, 0.25, 0.3], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
        }
    }

    private func allowed(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !prefs.focusMutedModes.contains(id) },
            set: { on in
                prefs.focusMutedModes.removeAll { $0 == id }
                if !on { prefs.focusMutedModes.append(id) }
            }
        )
    }

    private func note(_ text: String) -> some View {
        Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a `PermissionRow` shows and asks for: Isola's `Permission`s, plus Weather's location.
protocol PermissionKind {
    var title: String { get }
    var detail: String { get }
    @MainActor func status() -> PermissionStatus
    @MainActor func request(_ done: @escaping () -> Void)
    func openSystemSettings()
}

extension Permission: PermissionKind {}

/// A permission's live status (re-checked every 2 s while shown) and what to do about it.
/// `then` runs once a request is answered.
struct PermissionRow: View {
    let permission: any PermissionKind
    var then: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            LabeledContent {
                switch status {
                case .granted:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Button("Open Settings…") { permission.openSystemSettings() }
                case .notDetermined:
                    Button("Ask Permission…") {
                        if let key = askedKey { UserDefaults.standard.set(true, forKey: key) }
                        permission.request(then)
                    }
                }
            } label: {
                Text(permission.title)
                Text(permission.detail)
            }
        }
    }

    private var status: PermissionStatus {
        // The gallery shows a first run rather than probing this machine.
        if SystemModule.renderingGallery { return (permission as? Permission).map { $0 == .focus ? .notDetermined : .denied } ?? .notDetermined }
        let status = permission.status()
        // Accessibility never reads as denied, and macOS asks only once: after that it's System Settings.
        if status == .notDetermined, let key = askedKey, UserDefaults.standard.bool(forKey: key) { return .denied }
        return status
    }

    private var askedKey: String? {
        (permission as? Permission) == .accessibility ? "permission.accessibility.asked" : nil
    }
}
