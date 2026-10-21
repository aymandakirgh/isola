import AppKit
import IOKit.ps
import SwiftUI

/// Watches the internal battery (IOKit power-source notifications) and Low Power Mode.
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    struct Reading {
        var hasBattery = false
        var level: Double = 1
        var charging = false
        var plugged = true
        var toFull: Int?
        var toEmpty: Int?
        var watts: Int?
    }

    private var source: CFRunLoopSource?
    private var lastPlugged: Bool?
    /// Lowest warning threshold already announced in this discharge.
    private var warned: Double = 1

    func start() {
        apply(Self.read(), announce: false)
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PowerMonitor.shared.apply(PowerMonitor.read(), announce: true) } }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        PowerState.shared.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.lowPowerChanged(ProcessInfo.processInfo.isLowPowerModeEnabled) }
        }
    }

    nonisolated static func read() -> Reading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return Reading() }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Double ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Double ?? 100
            let minutes = { (key: String) -> Int? in (d[key] as? Int).flatMap { $0 > 0 ? $0 : nil } }
            let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
            return Reading(
                hasBattery: true,
                level: max > 0 ? min(1, current / max) : 0,
                charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                plugged: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                toFull: minutes(kIOPSTimeToFullChargeKey),
                toEmpty: minutes(kIOPSTimeToEmptyKey),
                watts: adapter?[kIOPSPowerAdapterWattsKey] as? Int
            )
        }
        return Reading()  // desktop Mac: always on AC, no battery
    }

    func apply(_ r: Reading, announce: Bool) {
        let s = PowerState.shared
        s.hasBattery = r.hasBattery
        s.level = r.level
        s.charging = r.charging
        s.pluggedIn = r.plugged
        s.timeToFull = r.toFull
        s.timeToEmpty = r.toEmpty
        s.adapterWatts = r.watts
        defer { lastPlugged = r.plugged; syncActivity() }
        guard r.hasBattery else { return }
        let prefs = SystemPreferences.shared
        if announce, let last = lastPlugged, last != r.plugged, prefs.chargingNotification {
            Island.shared.post(PowerItems.charger(connected: r.plugged, level: r.level))
        }
        if r.plugged { warned = 1; return }
        // Discharging: warn once at the chosen threshold, then again at 10%.
        guard prefs.lowBatteryNotification, announce else { return }
        for t in [prefs.lowBatteryThreshold, 0.1] where r.level <= t && t < warned {
            warned = t
            Island.shared.post(PowerItems.lowBattery(level: r.level), duration: 5)
            if prefs.lowBatterySound { Sounds.lowBattery() }
            break
        }
    }

    /// Debug simulation: treat `r` as a fresh change even if the real state matches.
    func simulate(_ r: Reading) {
        lastPlugged = !r.plugged
        if r.plugged || r.level > SystemPreferences.shared.lowBatteryThreshold { warned = 1 }
        apply(r, announce: true)
    }

    func lowPowerChanged(_ on: Bool) {
        guard on != PowerState.shared.lowPowerMode else { return }
        PowerState.shared.lowPowerMode = on
        if SystemPreferences.shared.lowPowerNotification { Island.shared.post(PowerItems.lowPower(on: on)) }
    }

    /// Charging live activity runs while plugged in (opt-in).
    func syncActivity() {
        let s = PowerState.shared
        if SystemPreferences.shared.chargingActivity, s.hasBattery, s.pluggedIn {
            if !Island.shared.isRunning(PowerItems.activityID) { Island.shared.start(PowerItems.chargingActivity()) }
        } else {
            Island.shared.end(PowerItems.activityID)
        }
    }
}

enum PowerItems {
    static let activityID = "system.charging"

    static func symbol(for level: Double) -> String {
        switch level {
        case ..<0.1: "battery.0percent"
        case ..<0.375: "battery.25percent"
        case ..<0.625: "battery.50percent"
        case ..<0.875: "battery.75percent"
        default: "battery.100percent"
        }
    }

    static func percent(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min" }

    @MainActor static func charger(connected: Bool, level: Double) -> IslandItem {
        IslandItem(id: "system.charger", kind: .notification) {
            Group {
                if connected {
                    BouncingSymbol(name: "bolt.fill", color: Palette.green, size: 16)
                } else {
                    Image(systemName: symbol(for: level)).islandSymbol(17).foregroundStyle(Palette.ink)
                }
            }
            .padding(.leading, 11)
        } trailing: {
            WingText(percent(level), color: connected ? Palette.green : Palette.ink)
        }
    }

    @MainActor static func lowBattery(level: Double) -> IslandItem {
        IslandItem(id: "system.lowBattery", kind: .notification) {
            Image(systemName: symbol(for: level)).islandSymbol(17).foregroundStyle(Palette.red).padding(.leading, 11)
        } trailing: {
            WingText(percent(level), color: Palette.red)
        }
        .peek(always: true) { PeekLabel(level <= 0.1 ? "Battery critically low" : "Low Battery") }
    }

    @MainActor static func lowPower(on: Bool) -> IslandItem {
        IslandItem(id: "system.lowPower", kind: .notification) {
            Image(systemName: "battery.50percent").islandSymbol(17).foregroundStyle(on ? Palette.amber : Palette.muted).padding(.leading, 11)
        } trailing: {
            WingText(on ? "On" : "Off", color: on ? Palette.amber : Palette.muted)
        }
        .peek(always: true) { PeekLabel("Low Power Mode") }
    }

    /// Live activity; `level`/`minutesToFull`/`watts`/`details` override the live state
    /// (gallery snapshots). Option-click switches its peek between time to full and details.
    @MainActor static func chargingActivity(level: Double? = nil, minutesToFull: Int? = nil, watts: Int? = nil, details: Bool? = nil) -> IslandItem {
        IslandItem(id: activityID, kind: .liveActivity, priority: 10) {
            Image(systemName: "bolt.fill").islandSymbol(15).foregroundStyle(Palette.green).padding(.leading, 12)
        } trailing: {
            ChargingRing(level: level).padding(.trailing, 10)
        }
        .peek(onHover: true) { ChargingPeek(level: level, minutesToFull: minutesToFull, watts: watts, details: details) }
        .onOptionTap {
            ChargingDetails.shared.shown.toggle()
            Island.shared.quickPeek(true, for: 4)
        }
    }
}

/// Whether the charging peek shows battery details rather than time to full.
@MainActor @Observable
final class ChargingDetails {
    static let shared = ChargingDetails()
    var shown = false
}

private struct ChargingRing: View {
    var level: Double?
    var body: some View { BatteryRing(level: level ?? PowerState.shared.level, color: Palette.green) }
}

private struct ChargingPeek: View {
    var level: Double?
    var minutesToFull: Int?
    var watts: Int?
    var details: Bool?
    var body: some View {
        let s = PowerState.shared
        let l = level ?? s.level
        let m = level == nil ? s.timeToFull : minutesToFull
        if details ?? ChargingDetails.shared.shown {
            // The level and the adapter charging it ("46% · 96 W adapter").
            PeekLabel("\(PowerItems.percent(l)) · " + ((level == nil ? s.adapterWatts : watts).map { "\($0) W adapter" } ?? "Charging"))
        } else {
            PeekLabel(l >= 0.995 ? "Charged · 100%" : m.map { "Full in \(PowerItems.minutes($0))" } ?? "Charging · \(PowerItems.percent(l))")
        }
    }
}

/// Text in a narrow wing: short, semibold, shrinks rather than spilling under the notch.
struct WingText: View {
    var text: String
    var color: Color
    init(_ text: String, color: Color = Palette.ink) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.trailing, 11)
    }
}

/// Caption under the notch while peeking.
struct PeekLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 4)
    }
}

/// SF Symbol that bounces once when it appears.
struct BouncingSymbol: View {
    var name: String
    var color: Color = Palette.ink
    var size: CGFloat = 16
    @StateObject private var trigger = BounceTrigger()

    var body: some View {
        Image(systemName: name)
            .islandSymbol(size)
            .foregroundStyle(color)
            .symbolEffect(.bounce, value: trigger.count)
            .onAppear { trigger.fire() }
    }
}

final class BounceTrigger: ObservableObject {
    @Published var count = 0
    func fire() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.count += 1 } }
}
