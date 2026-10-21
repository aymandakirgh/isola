import AppKit
import Observation
import SwiftUI

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }

/// Calendar, weather and timer settings (same persistence pattern as `Preferences`).
@MainActor @Observable
final class CalendarPreferences {
    static let shared = CalendarPreferences()

    // Calendar live activity and time-to-leave
    var liveActivity: Bool = load("calendar.liveActivity", true) { didSet { store.set(liveActivity, forKey: "calendar.liveActivity"); CalendarSource.shared.evaluate() } }
    /// Minutes before an event starts that its live activity appears.
    var leadMinutes: Int = load("calendar.leadMinutes", 10) { didSet { store.set(leadMinutes, forKey: "calendar.leadMinutes"); CalendarSource.shared.evaluate() } }
    var timeToLeave: Bool = load("calendar.timeToLeave", true) { didSet { store.set(timeToLeave, forKey: "calendar.timeToLeave") } }
    var leaveMinutes: Int = load("calendar.leaveMinutes", 15) { didSet { store.set(leaveMinutes, forKey: "calendar.leaveMinutes") } }

    // Which events show
    var showDeclined: Bool = load("calendar.showDeclined", false) { didSet { store.set(showDeclined, forKey: "calendar.showDeclined"); CalendarSource.shared.reload() } }
    var excludeSubscribed: Bool = load("calendar.excludeSubscribed", true) { didSet { store.set(excludeSubscribed, forKey: "calendar.excludeSubscribed"); CalendarSource.shared.reload() } }
    /// Calendar identifiers switched off in the calendar list.
    var excludedCalendars: [String] = load("calendar.excludedCalendars", []) { didSet { store.set(excludedCalendars, forKey: "calendar.excludedCalendars"); CalendarSource.shared.reload() } }
    /// Event ids dismissed with a swipe; "Restore dismissed" clears them.
    var dismissed: [String] = load("calendar.dismissed", []) { didSet { store.set(dismissed, forKey: "calendar.dismissed"); CalendarSource.shared.evaluate() } }

    // Expanded calendar look
    var calendarColors: Bool = load("calendar.colors", true) { didSet { store.set(calendarColors, forKey: "calendar.colors") } }
    var splitAllDay: Bool = load("calendar.splitAllDay", true) { didSet { store.set(splitAllDay, forKey: "calendar.splitAllDay") } }
    var lunar: Bool = load("calendar.lunar", false) { didSet { store.set(lunar, forKey: "calendar.lunar") } }
    /// "calendar", "fantastical" or "notion": what clicking today's date opens.
    var openWith: String = load("calendar.openWith", "calendar") { didSet { store.set(openWith, forKey: "calendar.openWith") } }
    /// Keep a quiet date activity in the island when nothing else is running.
    var idleActivity: Bool = load("calendar.idleActivity", false) { didSet { store.set(idleActivity, forKey: "calendar.idleActivity"); CalendarModule.updateIdleActivity() } }

    // Weather
    var weather: Bool = load("weather.enabled", true) { didSet { store.set(weather, forKey: "weather.enabled"); Weather.shared.refresh() } }
    var weatherCity: String = load("weather.city", "") { didSet { store.set(weatherCity, forKey: "weather.city") } }
    var weatherLatitude: Double? = store.object(forKey: "weather.lat") as? Double { didSet { store.set(weatherLatitude, forKey: "weather.lat") } }
    var weatherLongitude: Double? = store.object(forKey: "weather.lon") as? Double { didSet { store.set(weatherLongitude, forKey: "weather.lon") } }
    /// "auto" (from locale), "c" or "f".
    var weatherUnit: String = load("weather.unit", "auto") { didSet { store.set(weatherUnit, forKey: "weather.unit"); Weather.applyUnit() } }
    /// Show today's weather in the expanded calendar when the day has no events left.
    var weatherOnEmptyDay: Bool = load("weather.emptyDay", true) { didSet { store.set(weatherOnEmptyDay, forKey: "weather.emptyDay") } }
}

/// Module-internal calendar data the shared `CalendarState` doesn't carry.
@MainActor @Observable
final class CalendarModel {
    static let shared = CalendarModel()
    /// Start of day → number of events, for the week strip indicators.
    var weekCounts: [Date: Int] = [:]
    /// Events injected with `isolactl cal.event` (merged into today's list).
    var debugEvents: [CalendarEvent] = []
}

@MainActor
enum CalendarModule {
    static func start() {
        registerSettings()
        CalendarSource.shared.start()
        Weather.shared.start()
        updateIdleActivity()
        registerDebug()
    }

    static func registerSettings() {
        SettingsRegistry.add("calendar", title: "Calendar & Weather", symbol: "calendar", order: 50) { CalendarSettingsView() }
    }

    static func updateIdleActivity() {
        if CalendarPreferences.shared.idleActivity { Island.shared.start(CalendarItems.idle()) } else { Island.shared.end(CalendarItems.idleID) }
    }

    private static func registerDebug() {
        Debug.on("cal.event") { args in
            let minutes = Double(args["in"] ?? "5") ?? 5
            let start = Date().addingTimeInterval(minutes * 60)
            let event = CalendarEvent(
                id: "debug-\(UUID().uuidString)", title: args["title"] ?? "Design review", start: start,
                end: start.addingTimeInterval(45 * 60), calendarColor: .systemPurple, location: args["location"]
            )
            CalendarModel.shared.debugEvents.append(event)
            CalendarSource.shared.reload()
        }
        Debug.on("cal.leave") { args in
            let start = Date().addingTimeInterval(Double(CalendarPreferences.shared.leaveMinutes) * 60)
            let event = CalendarEvent(
                id: "debug-leave-\(UUID().uuidString)", title: args["title"] ?? "Dinner at Marta's", start: start,
                end: start.addingTimeInterval(3600), calendarColor: .systemOrange, location: args["location"] ?? "Via Roma 12"
            )
            Island.shared.post(CalendarItems.leave(event, now: Date()), duration: 6)
        }
        Debug.on("cal.clear") { _ in
            CalendarModel.shared.debugEvents = []
            CalendarPreferences.shared.dismissed = []
            CalendarSource.shared.reload()
        }
        Debug.on("timer.start") { CalendarTimer.shared.start(Double($0["seconds"] ?? "300") ?? 300) }
        Debug.on("timer.stop") { _ in CalendarTimer.shared.stop() }
        Debug.on("weather.set") { args in
            let w = WeatherState.shared
            if let t = args["temp"].flatMap(Double.init) { w.temperature = t }
            if let s = args["symbol"] { w.symbol = s }
            if let c = args["condition"] { w.condition = c }
            if let p = args["rain"].flatMap(Double.init) { w.precipitationChance = p }
            w.available = true
        }
    }

    // MARK: - Gallery

    static func gallery() {
        registerSettings()
        WeatherCode.selfCheck()
        CalendarText.selfCheck()

        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let review = CalendarEvent(
            id: "g-review", title: "Design review", start: now.addingTimeInterval(8 * 60 + 20),
            end: now.addingTimeInterval(53 * 60), calendarColor: .systemPurple, location: "Studio 3"
        )
        let dinner = CalendarEvent(
            id: "g-dinner", title: "Dinner at Marta's", start: now.addingTimeInterval(15 * 60),
            end: now.addingTimeInterval(2 * 3600), calendarColor: .systemOrange, location: "Via Roma 12, Bologna"
        )
        let events = [
            CalendarEvent(id: "g-bday", title: "Marta's birthday", start: day, end: day.addingTimeInterval(86400), calendarColor: .systemPink, isAllDay: true),
            CalendarEvent(id: "g-standup", title: "Stand-up", start: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(-3 * 3600 + 900), calendarColor: .systemTeal),
            review,
            CalendarEvent(id: "g-call", title: "Call with Luca", start: now.addingTimeInterval(2 * 3600 + 40 * 60), end: now.addingTimeInterval(3 * 3600 + 10 * 60), calendarColor: .systemBlue, location: "FaceTime"),
        ]
        var counts: [Date: Int] = [:]
        for offset in [-2, 0, 1, 3] { counts[Calendar.current.date(byAdding: .day, value: offset, to: day)!] = offset == 0 ? 3 : 1 }
        let weather = WeatherSnapshot(temperature: "21°", symbol: "cloud.sun.fill", condition: "Partly cloudy", detail: "Rain likely at 18:00 · 60%")
        let timer = TimerSnapshot(end: now.addingTimeInterval(4 * 60 + 12), duration: 5 * 60)

        let panel = CalendarPanel(events: events, weekCounts: counts, weather: weather, timer: nil, dismissedCount: 0, lunar: false, now: now)
        let emptyPanel = CalendarPanel(events: [events[0]], weekCounts: counts, weather: weather, timer: nil, dismissedCount: 2, lunar: true, now: now)
        let timerPanel = CalendarPanel(events: events, weekCounts: counts, weather: weather, timer: timer, dismissedCount: 0, lunar: false, now: now)

        for (suffix, g) in [("pill", NotchGeometry.pillPreview), ("notch", NotchGeometry.notchPreview)] {
            Gallery.island("calendar-activity-\(suffix)", item: CalendarItems.event(review, panel: panel), geometry: g)
            Gallery.island("calendar-leave-\(suffix)", item: CalendarItems.leave(dinner, now: now), geometry: g)
            Gallery.island("calendar-timer-\(suffix)", item: CalendarItems.timer(snapshot: timer), geometry: g)
        }
        Gallery.island("calendar-activity-peek", item: CalendarItems.event(review, panel: panel), peeking: true)
        Gallery.island("calendar-timer-done", item: CalendarItems.timerDone())
        Gallery.island("calendar-idle", item: CalendarItems.idle(panel: panel, nextEvent: review))
        Gallery.island("calendar-expanded-events", item: CalendarItems.event(review, panel: panel), expanded: true)
        Gallery.island("calendar-expanded-empty", item: CalendarItems.event(review, panel: emptyPanel), expanded: true)
        Gallery.island("calendar-expanded-timer", item: CalendarItems.event(review, panel: timerPanel), expanded: true, geometry: .notchPreview)
        Gallery.add("calendar-settings", size: CGSize(width: 560, height: 980)) {
            CalendarSettingsView().background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
