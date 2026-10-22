import AppKit
import Observation
import SwiftUI

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }

/// When an upcoming event's title peeks out of the island.
enum PeekTiming: String, CaseIterable, Identifiable {
    case appear, start, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appear: "Before event starts"
        case .start: "When event is starting"
        case .off: "Off"
        }
    }
}

/// Calendar, weather and timer settings (same persistence pattern as `Preferences`).
@MainActor @Observable
final class CalendarPreferences {
    static let shared = CalendarPreferences()

    // Calendar live activity and time-to-leave
    var liveActivity: Bool = load("calendar.liveActivity", true) { didSet { store.set(liveActivity, forKey: "calendar.liveActivity"); CalendarSource.shared.evaluate() } }
    /// Minutes before an event starts that its live activity appears.
    var leadMinutes: Int = load("calendar.leadMinutes", 10) { didSet { store.set(leadMinutes, forKey: "calendar.leadMinutes"); CalendarSource.shared.evaluate() } }
    /// End the activity once the event starts (after a 5-minute "Now") instead of counting down to its end.
    var hideDuringEvents: Bool = load("calendar.hideDuringEvents", false) {
        didSet { store.set(hideDuringEvents, forKey: "calendar.hideDuringEvents"); CalendarSource.shared.evaluate() }
    }
    /// The title peeks when the activity appears, when the event starts, or never…
    var peekTiming: PeekTiming = PeekTiming(rawValue: load("calendar.peekTiming", "appear")) ?? .appear {
        didSet { store.set(peekTiming.rawValue, forKey: "calendar.peekTiming") }
    }
    /// …for this many seconds.
    var peekDuration: Double = load("calendar.peekDuration", 3) { didSet { store.set(peekDuration, forKey: "calendar.peekDuration") } }
    var timeToLeave: Bool = load("calendar.timeToLeave", true) { didSet { store.set(timeToLeave, forKey: "calendar.timeToLeave") } }
    /// Seconds a time-to-leave alert stays.
    var leaveDuration: Double = load("calendar.leaveDuration", 6) { didSet { store.set(leaveDuration, forKey: "calendar.leaveDuration") } }
    /// With location access, alerts come at start − travel time − `leaveBuffer` minutes…
    var travelMode: TravelMode = TravelMode(rawValue: load("calendar.travelMode", "driving")) ?? .driving {
        didSet { store.set(travelMode.rawValue, forKey: "calendar.travelMode") }
    }
    var leaveBuffer: Int = load("calendar.leaveBuffer", 5) { didSet { store.set(leaveBuffer, forKey: "calendar.leaveBuffer") } }
    /// …otherwise a fixed number of minutes before the start.
    var leaveMinutes: Int = load("calendar.leaveMinutes", 15) { didSet { store.set(leaveMinutes, forKey: "calendar.leaveMinutes") } }

    // Which events show
    var showDeclined: Bool = load("calendar.showDeclined", false) { didSet { store.set(showDeclined, forKey: "calendar.showDeclined"); CalendarSource.shared.reload() } }
    var excludeSubscribed: Bool = load("calendar.excludeSubscribed", true) { didSet { store.set(excludeSubscribed, forKey: "calendar.excludeSubscribed"); CalendarSource.shared.reload() } }
    /// Calendar identifiers switched off in the calendar list.
    var excludedCalendars: [String] = load("calendar.excludedCalendars", []) { didSet { store.set(excludedCalendars, forKey: "calendar.excludedCalendars"); CalendarSource.shared.reload() } }
    /// Event ids dismissed with a swipe; "Restore dismissed" clears them.
    var dismissed: [String] = load("calendar.dismissed", []) { didSet { store.set(dismissed, forKey: "calendar.dismissed"); CalendarSource.shared.evaluate() } }

    // Calendar look (colours also tint the live activity, its peek and the Lock Screen widget)
    var calendarColors: Bool = load("calendar.colors", true) { didSet { store.set(calendarColors, forKey: "calendar.colors"); CalendarSource.shared.evaluate() } }
    var splitAllDay: Bool = load("calendar.splitAllDay", true) { didSet { store.set(splitAllDay, forKey: "calendar.splitAllDay") } }
    var lunar: Bool = load("calendar.lunar", false) { didSet { store.set(lunar, forKey: "calendar.lunar") } }
    /// The expanded calendar draws the whole month (a taller panel) instead of the week.
    var monthView: Bool = load("calendar.monthView", false) {
        didSet { store.set(monthView, forKey: "calendar.monthView"); CalendarSource.shared.reload(); CalendarModule.refreshItems() }
    }
    /// Dots under days with events…
    var eventIndicators: Bool = load("calendar.eventIndicators", true) { didSet { store.set(eventIndicators, forKey: "calendar.eventIndicators") } }
    /// …in up to three of their calendars' colours.
    var coloredIndicators: Bool = load("calendar.coloredIndicators", true) { didSet { store.set(coloredIndicators, forKey: "calendar.coloredIndicators") } }
    /// "calendar", "fantastical" or "notion": what clicking today's date opens.
    var openWith: String = load("calendar.openWith", "calendar") { didSet { store.set(openWith, forKey: "calendar.openWith") } }
    /// Keep a quiet date activity in the island when nothing else is running.
    var idleActivity: Bool = load("calendar.idleActivity", false) { didSet { store.set(idleActivity, forKey: "calendar.idleActivity"); CalendarModule.updateIdleActivity() } }

    // Sounds (turning one on plays it once as a preview)
    var hourlyChime: Bool = load("calendar.hourlyChime", false) {
        didSet { store.set(hourlyChime, forKey: "calendar.hourlyChime"); HourlyChime.schedule(); if hourlyChime { CalendarSounds.chime() } }
    }
    /// When an event is announced, or with the start peek, when it starts.
    var eventSound: Bool = load("calendar.eventSound", false) {
        didSet { store.set(eventSound, forKey: "calendar.eventSound"); if eventSound { CalendarSounds.event() } }
    }
    /// With each time-to-leave alert.
    var notificationSound: Bool = load("calendar.notificationSound", false) {
        didSet { store.set(notificationSound, forKey: "calendar.notificationSound"); if notificationSound { CalendarSounds.alert() } }
    }

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
    /// Every loaded event, by start: the week (or the month view's grid) and tomorrow. The
    /// expanded calendar finds tomorrow's and a picked day's events here.
    var events: [CalendarEvent] = []
    /// Start of day → number of events and up to 3 of their calendars' colours, for the dots.
    var weekCounts: [Date: Int] = [:]
    var weekColors: [Date: [NSColor]] = [:]
    /// A day picked in the expanded calendar's week strip or month (nil: today).
    var selectedDay: Date?
    /// Events injected with `isolactl cal.event` (merged into today's list).
    var debugEvents: [CalendarEvent] = []
}

/// Calendar › Sounds, played by the events and as each setting's preview.
@MainActor
enum CalendarSounds {
    static func chime() { Sounds.play("Tink", volume: 0.5) }
    static func event() { Sounds.play("Glass") }
    static func alert() { Sounds.play("Ping") }
}

/// Play hourly chime: a one-shot timer for the next full hour, armed again after each chime, at
/// midnight and on wake (timers stall while the Mac sleeps; an hour slept through stays silent).
@MainActor
enum HourlyChime {
    private static var timer: Timer?

    static func start() {
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { schedule() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { schedule() }
        }
        schedule()
    }

    static func schedule() {
        timer?.invalidate()
        timer = nil
        guard CalendarPreferences.shared.hourlyChime else { return }
        let hour = nextHour(after: Date())
        let t = Timer(fire: hour, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                if Date().timeIntervalSince(hour) < 60 { CalendarSounds.chime() }
                schedule()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static var next: Date? { timer?.fireDate }

    nonisolated static func nextHour(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) ?? date.addingTimeInterval(3600)
    }
}

@MainActor
enum CalendarModule {
    static func start() {
        registerSettings()
        CalendarSource.shared.start()
        Weather.shared.start()
        updateIdleActivity()
        HourlyChime.start()
        registerDebug()
    }

    static func registerSettings() {
        SettingsRegistry.add("calendar", title: "Calendar & Weather", symbol: "calendar", order: 50, group: "liveActivities") { CalendarSettingsView() }
    }

    static func updateIdleActivity() {
        if CalendarPreferences.shared.idleActivity { Island.shared.start(CalendarItems.idle()) } else { Island.shared.end(CalendarItems.idleID) }
    }

    /// The month view changes the panel's size, which running items fix when they're made.
    static func refreshItems() {
        updateIdleActivity()
        CalendarSource.shared.evaluate()
        if CalendarTimer.shared.snapshot != nil { Island.shared.update(CalendarItems.timer()) }
    }

    private static func registerDebug() {
        // `in` and `length` are minutes (a negative `in` with a long `length` makes a multi-day event).
        Debug.on("cal.event") { args in
            let minutes = Double(args["in"] ?? "5") ?? 5
            let start = Date().addingTimeInterval(minutes * 60)
            let event = CalendarEvent(
                id: "debug-\(UUID().uuidString)", title: args["title"] ?? "Design review", start: start,
                end: start.addingTimeInterval((Double(args["length"] ?? "45") ?? 45) * 60), calendarColor: .systemPurple, location: args["location"]
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
            let travel = args["travel"].flatMap(Double.init).map { $0 * 60 }  // minutes, as if from Apple Maps
            CalendarSource.shared.postLeave(event, now: Date(), travel: travel)
        }
        // e.g. isolactl cal.pref colors=0 travelMode=walking leaveBuffer=10 peek=start peekDuration=5 hideDuring=1
        // monthView=1 dots=1 coloredDots=1 chime=1 eventSound=1 alertSound=1 leaveDuration=10 (`cal.state` reads them back)
        Debug.on("cal.pref") { args in
            let p = CalendarPreferences.shared
            func on(_ key: String) -> Bool? { args[key].map { $0 == "1" } }
            if let v = on("colors") { p.calendarColors = v }
            if let v = args["travelMode"].flatMap(TravelMode.init(rawValue:)) { p.travelMode = v }
            if let v = args["leaveBuffer"].flatMap(Int.init) { p.leaveBuffer = v }
            if let v = args["peek"].flatMap(PeekTiming.init(rawValue:)) { p.peekTiming = v }
            if let v = args["peekDuration"].flatMap(Double.init) { p.peekDuration = v }
            if let v = on("hideDuring") { p.hideDuringEvents = v }
            if let v = on("monthView") { p.monthView = v }
            if let v = on("dots") { p.eventIndicators = v }
            if let v = on("coloredDots") { p.coloredIndicators = v }
            if let v = on("chime") { p.hourlyChime = v }
            if let v = on("eventSound") { p.eventSound = v }
            if let v = on("alertSound") { p.notificationSound = v }
            if let v = args["leaveDuration"].flatMap(Double.init) { p.leaveDuration = v }
        }
        // The right-click menu of what the island shows: `cal.menu.state` lists it, `cal.menu run=<title>` picks an entry.
        Debug.on("cal.menu.state") { _ in
            let titles = (Island.shared.current?.contextMenu?() ?? []).compactMap { entry -> String? in
                guard case let .action(title, _, _, _, _, _) = entry else { return nil }
                return title
            }
            Debug.reply(titles.isEmpty ? "no calendar menu for \(Island.shared.current?.id ?? "nothing")" : titles.joined(separator: " | "))
        }
        Debug.on("cal.menu") { args in
            for case let .action(title, _, _, _, _, run) in Island.shared.current?.contextMenu?() ?? [] where title == args["run"] { run() }
        }
        // Pick a day in the expanded calendar: `offset=1` is tomorrow, `offset=none` goes back to today.
        Debug.on("cal.day") { args in
            let today = Calendar.current.startOfDay(for: Date())
            CalendarModel.shared.selectedDay = args["offset"].flatMap(Int.init).flatMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        }
        Debug.on("cal.chime") { _ in CalendarSounds.chime() }
        Debug.on("cal.state") { _ in
            let state = CalendarState.shared, p = CalendarPreferences.shared, model = CalendarModel.shared
            Debug.reply(
                "authorized=\(state.authorized) today=\(state.today.count) loaded=\(model.events.count) following=\(CalendarSource.shared.shown?.title ?? "none") "
                    + "picked=\(model.selectedDay.map { CalendarText.dayTitle($0) } ?? "today") location=\(Weather.shared.locationAuthorized) "
                    + "peek=\(p.peekTiming.rawValue)/\(Int(p.peekDuration))s hideDuring=\(p.hideDuringEvents) monthView=\(p.monthView) "
                    + "dots=\(p.eventIndicators)/\(p.coloredIndicators ? "colored" : "plain") chime=\(HourlyChime.next.map { CalendarText.time($0) } ?? "off") "
                    + "eventSound=\(p.eventSound) alertSound=\(p.notificationSound) leaveDuration=\(Int(p.leaveDuration))s travel: \(TravelTime.shared.report)"
            )
        }
        Debug.on("cal.clear") { _ in
            CalendarModel.shared.debugEvents = []
            CalendarPreferences.shared.dismissed = []
            CalendarSource.shared.reload()
        }
        Debug.on("timer.start") { CalendarTimer.shared.start(Double($0["seconds"] ?? "300") ?? 300) }
        Debug.on("timer.stop") { _ in CalendarTimer.shared.stop() }
        Debug.on("timer.pause") { _ in CalendarTimer.shared.togglePause() }
        Debug.on("weather.set") { args in
            let w = WeatherState.shared
            if let t = args["temp"].flatMap(Double.init) { w.temperature = t }
            if let s = args["symbol"] { w.symbol = s }
            if let c = args["condition"] { w.condition = c }
            if let p = args["rain"].flatMap(Double.init) { w.precipitationChance = p }
            if let d = args["detail"] { w.precipitationDetail = d.isEmpty ? nil : d }  // e.g. detail="Snow from 07:00 · 80%"
            w.available = true
        }
    }

    // MARK: - Gallery

    static func gallery() {
        registerSettings()
        selfCheck()
        WeatherCode.selfCheck()
        CalendarText.selfCheck()
        CalendarSource.selfCheck()
        TravelTime.selfCheck()
        Weather.selfCheck()

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
        let weather = WeatherSnapshot(temperature: "21°", symbol: "cloud.sun.fill", condition: "Partly cloudy", detail: "Rain at 18:00 · 60%")
        let timer = TimerSnapshot(end: now.addingTimeInterval(4 * 60 + 12), duration: 5 * 60)

        let panel = CalendarPanel(events: events, weekCounts: counts, weather: weather, timer: nil, dismissedCount: 0, lunar: false, now: now)
        let emptyPanel = CalendarPanel(events: [events[0]], weekCounts: counts, weather: weather, timer: nil, dismissedCount: 2, lunar: true, now: now)
        let timerPanel = CalendarPanel(events: events, weekCounts: counts, weather: weather, timer: timer, dismissedCount: 0, lunar: false, now: now)
        // Split days: an all-day offsite and a timed conference, both yesterday → tomorrow.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        let multiDay = [
            CalendarEvent(id: "g-offsite", title: "Lisbon offsite", start: yesterday, end: yesterday.addingTimeInterval(3 * 86400), calendarColor: .systemGreen, isAllDay: true),
            CalendarEvent(id: "g-conf", title: "Web Summit", start: yesterday.addingTimeInterval(9 * 3600), end: yesterday.addingTimeInterval(2 * 86400 + 18 * 3600), calendarColor: .systemBlue, location: "FIL, Lisbon"),
            review,
        ]
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: day)!
        let multiDayPanel = CalendarPanel(
            events: multiDay, weekCounts: CalendarSource.counts(multiDay, in: week), weather: weather, timer: nil, dismissedCount: 0, lunar: false, now: now
        )

        for (suffix, g) in [("pill", NotchGeometry.pillPreview), ("notch", NotchGeometry.notchPreview)] {
            Gallery.island("calendar-activity-\(suffix)", item: CalendarItems.event(review, panel: panel), geometry: g)
            Gallery.island("calendar-leave-\(suffix)", item: CalendarItems.leave(dinner, now: now), geometry: g)
            Gallery.island("calendar-timer-\(suffix)", item: CalendarItems.timer(snapshot: timer), geometry: g)
        }
        Gallery.island("calendar-leave-travel", item: CalendarItems.leave(dinner, now: now, travel: 25 * 60))
        Gallery.island("calendar-activity-peek", item: CalendarItems.event(review, panel: panel), peeking: true)
        Gallery.island("calendar-activity-peek-nocolor", item: CalendarItems.event(review, panel: panel, colors: false), peeking: true)
        Gallery.island("calendar-timer-paused", item: CalendarItems.timer(snapshot: TimerSnapshot(end: timer.end, duration: timer.duration, paused: 252)))
        Gallery.island("calendar-timer-done", item: CalendarItems.timerDone())
        Gallery.island("calendar-idle", item: CalendarItems.idle(panel: panel, nextEvent: review))
        Gallery.island("calendar-expanded-events", item: CalendarItems.event(review, panel: panel), expanded: true)
        Gallery.island("calendar-expanded-empty", item: CalendarItems.event(review, panel: emptyPanel), expanded: true)
        Gallery.island("calendar-expanded-multiday", item: CalendarItems.event(review, panel: multiDayPanel), expanded: true)
        Gallery.island("calendar-expanded-timer", item: CalendarItems.event(review, panel: timerPanel), expanded: true, geometry: .notchPreview)

        // Under way: the time left (until it ends), or "Now" while hiding during events.
        let ongoing = CalendarEvent(
            id: "g-workshop", title: "Workshop", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(25 * 60 + 10),
            calendarColor: .systemIndigo, location: "Room 2"
        )
        for (suffix, g) in [("pill", NotchGeometry.pillPreview), ("notch", NotchGeometry.notchPreview)] {
            Gallery.island("calendar-activity-left-\(suffix)", item: CalendarItems.event(ongoing, panel: panel), geometry: g)
        }
        Gallery.island("calendar-activity-left-peek", item: CalendarItems.event(ongoing, panel: panel), peeking: true)
        Gallery.island("calendar-activity-now", item: CalendarItems.event(ongoing, panel: panel, timeLeft: false))

        // Dots: in calendar colours (up to 3 a day), or none.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        func at(_ days: Int, _ hours: Double, _ title: String, _ color: NSColor, minutes: Double = 45) -> CalendarEvent {
            let start = Calendar.current.date(byAdding: .day, value: days, to: day)!.addingTimeInterval(hours * 3600)
            return CalendarEvent(id: "g-\(title)-\(days)", title: title, start: start, end: start.addingTimeInterval(minutes * 60), calendarColor: color, location: nil)
        }
        let busyWeek = events + [
            at(-2, 10, "Dentist", .systemRed), at(1, 9, "Flight to Lisbon", .systemBlue, minutes: 150), at(1, 13, "Lunch with Ada", .systemOrange),
            at(1, 18, "Gym", .systemGreen), at(1, 20, "Concert", .systemPink), at(3, 11, "Review", .systemPurple),
        ]
        let span = CalendarSource.range(for: day, monthView: true)
        func panelWith(_ list: [CalendarEvent], dots: DayDots = .colored, monthView: Bool = false, selected: Date? = nil, card: Bool = true, at time: Date = now) -> CalendarPanel {
            CalendarPanel(
                events: list, weekCounts: CalendarSource.counts(list, in: span), weekColors: CalendarSource.colors(list, in: span), weather: weather,
                timer: nil, dismissedCount: 0, lunar: false, now: time, weatherOnEmptyDay: card, monthView: monthView, dots: dots, selectedDay: selected
            )
        }
        Gallery.island("calendar-expanded-colored-dots", item: CalendarItems.event(review, panel: panelWith(busyWeek)), expanded: true)
        Gallery.island("calendar-expanded-no-dots", item: CalendarItems.event(review, panel: panelWith(busyWeek, dots: .none)), expanded: true)
        let month = CalendarItems.panelSize(monthView: true)
        for (suffix, g) in [("pill", NotchGeometry.pillPreview), ("notch", NotchGeometry.notchPreview)] {
            Gallery.island("calendar-expanded-month-\(suffix)", item: CalendarItems.event(review, panel: panelWith(busyWeek, monthView: true), size: month), expanded: true, geometry: g)
        }
        // More than fits: "+2 more all-day", "3 more events".
        let crowded = [
            at(0, 0, "Marta's birthday", .systemPink, minutes: 1440), at(0, 0, "Public holiday", .systemRed, minutes: 1440), at(0, 0, "Out of office", .systemGray, minutes: 1440),
        ].map { e -> CalendarEvent in var e = e; e.isAllDay = true; return e } + [
            review, CalendarEvent(id: "g-sync", title: "Team sync", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), calendarColor: .systemTeal),
            CalendarEvent(id: "g-1on1", title: "1:1 with Sara", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000), calendarColor: .systemBlue),
            CalendarEvent(id: "g-yoga", title: "Yoga", start: now.addingTimeInterval(4 * 3600), end: now.addingTimeInterval(5 * 3600), calendarColor: .systemGreen),
        ]
        Gallery.island("calendar-expanded-more-allday", item: CalendarItems.event(review, panel: panelWith(crowded)), expanded: true)
        Gallery.island("calendar-expanded-more-events", item: CalendarItems.event(review, panel: panelWith(Array(crowded.dropFirst(3)))), expanded: true)
        Gallery.island("calendar-expanded-more-month", item: CalendarItems.event(review, panel: panelWith(Array(crowded.dropFirst(3)), monthView: true), size: month), expanded: true)
        // Today done: "That’s all for today"; nothing at all: "Nothing planned today"; tomorrow's events once today
        // is over, or with the weather card on, the card and tomorrow's line.
        let late = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now)!
        Gallery.island("calendar-expanded-done", item: CalendarItems.event(review, panel: panelWith([at(0, 9, "Stand-up", .systemTeal)], at: late)), expanded: true)
        Gallery.island("calendar-expanded-clear", item: CalendarItems.event(review, panel: panelWith([], at: late)), expanded: true)
        let later = busyWeek.filter { $0.start >= tomorrow }
        Gallery.island("calendar-expanded-tomorrow", item: CalendarItems.event(review, panel: panelWith(later, card: false, at: late)), expanded: true)
        Gallery.island("calendar-expanded-tomorrow-weather", item: CalendarItems.event(review, panel: panelWith(later, at: late)), expanded: true)
        // The month view under today's all-day chip has no room for the heading: tomorrow's rows go on without it.
        Gallery.island("calendar-expanded-tomorrow-month", item: CalendarItems.event(review, panel: panelWith([events[0]] + later, monthView: true, card: false, at: late), size: month), expanded: true)
        // A picked day: its events, or a day with none.
        Gallery.island("calendar-expanded-picked", item: CalendarItems.event(review, panel: panelWith(busyWeek, selected: tomorrow)), expanded: true)
        Gallery.island("calendar-expanded-picked-clear", item: CalendarItems.event(review, panel: panelWith(busyWeek, selected: Calendar.current.date(byAdding: .day, value: 2, to: day)!)), expanded: true)

        // Right-click menus: an event with a call, one without, and the date or timer.
        let call = URL(string: "https://us02web.zoom.us/j/123")!
        for (name, entries) in [("calendar-menu-event", CalendarMenu.entries(for: review, meeting: call, app: "Calendar")),
                                ("calendar-menu-event-nolink", CalendarMenu.entries(for: review, meeting: nil, app: "Fantastical")),
                                ("calendar-menu-date", CalendarMenu.openApp("Calendar"))] {
            Gallery.add(name, size: CGSize(width: 300, height: 170), hosted: true) { StatusMenuMock(entries: entries).background(Color(nsColor: .windowBackgroundColor)) }
        }
        Gallery.add("calendar-settings", size: CGSize(width: 560, height: 1640)) {
            CalendarSettingsView().background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// Runs with the gallery: the right-click menus' entries and the chime's next hour.
    static func selfCheck() {
        let e = CalendarEvent(id: "m", title: "Sync", start: Date(), end: Date().addingTimeInterval(1800), calendarColor: .systemBlue)
        func titles(_ entries: [MenuEntry]) -> [String] {
            entries.compactMap { entry -> String? in
                guard case let .action(title, _, _, _, _, _) = entry else { return nil }
                return title
            }
        }
        precondition(titles(CalendarMenu.entries(for: e, meeting: URL(string: "https://meet.google.com/abc"), app: "Calendar"))
            == ["Join Google Meet", "Open in Calendar", "Dismiss Event"], "event menu with a call")
        precondition(titles(CalendarMenu.entries(for: e, meeting: nil, app: "Notion Calendar")) == ["Open in Notion Calendar", "Dismiss Event"], "event menu without")
        precondition(CalendarItems.leave(e, now: Date()).contextMenu != nil && CalendarItems.leave(e, now: Date()).onOptionTap != nil,
                     "time to leave has its event's menu and Option-click")
        let cal = Calendar(identifier: .gregorian)
        let t = DateComponents(calendar: cal, year: 2026, month: 10, day: 22, hour: 14, minute: 59, second: 59).date!
        precondition(HourlyChime.nextHour(after: t, calendar: cal) == t.addingTimeInterval(1)
            && HourlyChime.nextHour(after: t.addingTimeInterval(1), calendar: cal) == t.addingTimeInterval(3601), "the next full hour, strictly after")
    }
}
