import Observation
import SwiftUI

private let store = UserDefaults.standard
private func flag(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }

/// Settings for system-driven notifications and live activities.
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
    var lowBatteryNotification = flag("system.lowBatteryNotification", true) {
        didSet { store.set(lowBatteryNotification, forKey: "system.lowBatteryNotification") }
    }
    /// First warning level (0...1); a second, critical warning always fires at 10%.
    var lowBatteryThreshold = store.object(forKey: "system.lowBatteryThreshold") as? Double ?? 0.2 {
        didSet { store.set(lowBatteryThreshold, forKey: "system.lowBatteryThreshold") }
    }
    var lowBatterySound = flag("system.lowBatterySound", true) {
        didSet { store.set(lowBatterySound, forKey: "system.lowBatterySound") }
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
    var deviceLowBattery = flag("system.deviceLowBattery", true) {
        didSet { store.set(deviceLowBattery, forKey: "system.deviceLowBattery") }
    }
    var deviceLowBatterySound = flag("system.deviceLowBatterySound", true) {
        didSet { store.set(deviceLowBatterySound, forKey: "system.deviceLowBatterySound") }
    }

    // Focus
    var focusNotification = flag("system.focusNotification", true) {
        didSet { store.set(focusNotification, forKey: "system.focusNotification") }
    }
    var focusActivity = flag("system.focusActivity", false) {
        didSet { store.set(focusActivity, forKey: "system.focusActivity"); FocusMonitor.shared.syncActivity() }
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
                Toggle("Low battery warning", isOn: $prefs.lowBatteryNotification)
                Picker("Warn at", selection: $prefs.lowBatteryThreshold) {
                    ForEach([0.1, 0.15, 0.2, 0.25, 0.3], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
                .disabled(!prefs.lowBatteryNotification)
                Toggle("Low battery sound", isOn: $prefs.lowBatterySound)
                    .disabled(!prefs.lowBatteryNotification)
                Toggle("Low Power Mode", isOn: $prefs.lowPowerNotification)
            }
            Section("Connectivity") {
                Toggle("Device connected and disconnected", isOn: $prefs.bluetoothNotification)
                Toggle("Include keyboards, mice and other devices", isOn: $prefs.bluetoothAllDevices)
                Toggle("Low battery warning for devices", isOn: $prefs.deviceLowBattery)
                Toggle("Low battery sound for devices", isOn: $prefs.deviceLowBatterySound)
                    .disabled(!prefs.deviceLowBattery)
            }
            Section("Focus") {
                Toggle("Focus changes", isOn: $prefs.focusNotification)
                Toggle("Focus live activity", isOn: $prefs.focusActivity)
            }
            Section("Lock") {
                Toggle("Lock live activity", isOn: $prefs.lockActivity)
                Toggle("Sound on unlock", isOn: $core.unlockSound)
                Toggle("Sound on lock", isOn: $core.lockSound)
            }
        }
        .formStyle(.grouped)
    }
}
