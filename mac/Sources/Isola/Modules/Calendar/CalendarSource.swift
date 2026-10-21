import AppKit
import EventKit

/// EventKit → `CalendarState`, plus the event live activity and time-to-leave alerts.
/// Never prompts on its own: access is requested only from the settings button.
@MainActor
final class CalendarSource {
    static let shared = CalendarSource()
    private var store = EKEventStore()
    private var ticker: Timer?
    private var announced: String?
    private var leaveNotified: Set<String> = []

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func start() {
        let nc = NotificationCenter.default
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { CalendarSource.shared.reload() } }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarSource.shared.tick() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarSource.shared.tick() }
        }
        reload()
    }

    /// Access can be granted elsewhere (onboarding, System Settings): reload when it flips.
    private func tick() {
        guard authorized != CalendarState.shared.authorized else { return evaluate() }
        store = EKEventStore()  // a store created before access was granted can stay empty
        reload()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { _, _ in
            Task { @MainActor in CalendarSource.shared.reload() }
        }
    }

    /// Calendars offered in settings (subscribed ones too, so they can be listed).
    func calendars() -> [EKCalendar] {
        authorized ? store.calendars(for: .event).sorted { $0.title.localizedCompare($1.title) == .orderedAscending } : []
    }

    func reload() {
        let state = CalendarState.shared
        let model = CalendarModel.shared
        let prefs = CalendarPreferences.shared
        state.authorized = authorized
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: day)!
        let week = cal.dateInterval(of: .weekOfYear, for: day) ?? DateInterval(start: day, end: tomorrow)
        var events = model.debugEvents

        if authorized {
            let calendars = store.calendars(for: .event).filter {
                !prefs.excludedCalendars.contains($0.calendarIdentifier) && !(prefs.excludeSubscribed && $0.type == .subscription)
            }
            let predicate = store.predicateForEvents(withStart: week.start, end: week.end, calendars: calendars)
            let found = calendars.isEmpty ? [] : store.events(matching: predicate).filter { prefs.showDeclined || !Self.declined($0) }
            events += found.map(Self.map)
        }
        // Multi-day events are listed on every day they cover, and dotted on each of them.
        state.today = events.filter { $0.end > day && $0.start < tomorrow }.sorted { $0.start < $1.start }
        model.weekCounts = Self.counts(events, in: week)
        evaluate()
    }

    /// Start of day → events on it, for the week strip.
    static func counts(_ events: [CalendarEvent], in week: DateInterval) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for e in events { for day in e.days(in: week) { counts[day, default: 0] += 1 } }
        return counts
    }

    /// Runs every 30 s: show the next event's live activity, fire time-to-leave alerts.
    func evaluate() {
        let prefs = CalendarPreferences.shared
        let now = Date()
        // Keyed to the real start: the later days of a multi-day event have none to count down to.
        let upcoming = CalendarState.shared.today.first {
            !$0.isAllDay && !prefs.dismissed.contains($0.id)
                && $0.start > now.addingTimeInterval(-5 * 60)  // keep "Now" for 5 min after it starts
                && $0.start <= now.addingTimeInterval(Double(prefs.leadMinutes) * 60)
        }
        if prefs.liveActivity, let event = upcoming {
            Island.shared.start(CalendarItems.event(event))
            if announced != event.id {
                announced = event.id
                // Show the title for a moment when the event first appears.
                if Island.shared.current?.id == CalendarItems.eventID { Island.shared.quickPeek(true, for: 3) }
            }
        } else {
            announced = nil
            Island.shared.end(CalendarItems.eventID)
        }

        guard prefs.timeToLeave else { return }
        for e in CalendarState.shared.today where !(e.location ?? "").isEmpty && !e.isAllDay && !leaveNotified.contains(e.id) {
            let lead = e.start.timeIntervalSince(now)
            if lead > 0, lead <= Double(prefs.leaveMinutes) * 60 {
                leaveNotified.insert(e.id)
                Island.shared.post(CalendarItems.leave(e, now: now), duration: 6)
                break
            }
        }
    }

    func dismiss(_ id: String) {
        CalendarPreferences.shared.dismissed.append(id)
    }

    /// Opens the calendar app chosen in settings (Calendar, Fantastical, Notion Calendar).
    static func openCalendarApp() {
        let ids = ["fantastical": "com.flexibits.fantastical2.mac", "notion": "com.cron.electron"]
        let preferred = ids[CalendarPreferences.shared.openWith]
        let url = preferred.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
        if let url { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    static func isInstalled(_ choice: String) -> Bool {
        let ids = ["calendar": "com.apple.iCal", "fantastical": "com.flexibits.fantastical2.mac", "notion": "com.cron.electron"]
        return ids[choice].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private static func map(_ e: EKEvent) -> CalendarEvent {
        // Recurring events share an identifier; the start date keeps occurrences apart.
        let id = "\(e.eventIdentifier ?? e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))"
        let location = e.structuredLocation?.title ?? e.location
        return CalendarEvent(
            id: id, title: e.title ?? "Untitled", start: e.startDate, end: e.endDate,
            calendarColor: e.calendar.color ?? .systemBlue, location: location?.isEmpty == true ? nil : location, isAllDay: e.isAllDay
        )
    }

    /// Runs with the gallery (`Isola --gallery`): multi-day splitting.
    static func selfCheck() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func at(_ days: Int, _ hours: Double) -> Date { cal.date(byAdding: .day, value: days, to: day)!.addingTimeInterval(hours * 3600) }
        func event(_ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: "check", title: "Check", start: start, end: end, calendarColor: .systemBlue, isAllDay: allDay)
        }
        let trip = event(at(0, 22), at(2, 7))
        precondition(trip.days() == [at(0, 0), at(1, 0), at(2, 0)])
        precondition(event(at(0, 10), at(1, 0)).days() == [at(0, 0)], "an end at midnight stays on its day")
        precondition(event(at(0, 0), at(1, 0), allDay: true).days() == [at(0, 0)])
        precondition(event(at(0, 9), at(0, 9)).days() == [at(0, 0)], "a zero-length event still has a day")
        precondition(counts([trip], in: DateInterval(start: at(1, 0), end: at(8, 0))) == [at(1, 0): 1, at(2, 0): 1])
        precondition(CalendarText.span(trip, on: at(0, 23))?.hasPrefix("Day 1 of 3 · from ") == true)
        precondition(CalendarText.span(trip, on: at(1, 12)) == "Day 2 of 3")
        precondition(CalendarText.span(trip, on: at(2, 3))?.hasPrefix("Day 3 of 3 · until ") == true)
        precondition(CalendarText.span(event(at(0, 10), at(0, 11)), on: at(0, 10)) == nil)
    }
}

extension CalendarEvent {
    /// Start of each day the event covers, clipped to `range`. An end at midnight stays
    /// on the day before; a zero-length event still covers its own day.
    func days(in range: DateInterval = DateInterval(start: .distantPast, end: .distantFuture)) -> [Date] {
        let cal = Calendar.current
        let last = min(max(end.addingTimeInterval(-1), start), range.end.addingTimeInterval(-1))
        var days: [Date] = []
        var day = cal.startOfDay(for: max(start, range.start))
        while day <= last {
            days.append(day)
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return days
    }
}
