import AppKit
import EventKit

/// EventKit → `CalendarState`, plus the event live activity and time-to-leave alerts.
/// Never prompts on its own: access is requested only from the settings button.
@MainActor
final class CalendarSource {
    static let shared = CalendarSource()
    let store = EKEventStore()
    private var ticker: Timer?
    private var announced: String?
    private var leaveNotified: Set<String> = []

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func start() {
        let nc = NotificationCenter.default
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { CalendarSource.shared.reload() } }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarSource.shared.evaluate() }
        }
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
        var today = model.debugEvents
        var counts: [Date: Int] = [:]
        for e in model.debugEvents { counts[cal.startOfDay(for: e.start), default: 0] += 1 }

        if authorized, let week = cal.dateInterval(of: .weekOfYear, for: Date()) {
            let calendars = store.calendars(for: .event).filter {
                !prefs.excludedCalendars.contains($0.calendarIdentifier) && !(prefs.excludeSubscribed && $0.type == .subscription)
            }
            let predicate = store.predicateForEvents(withStart: week.start, end: week.end, calendars: calendars)
            let events = calendars.isEmpty ? [] : store.events(matching: predicate).filter { prefs.showDeclined || !Self.declined($0) }
            for e in events {
                counts[cal.startOfDay(for: e.startDate), default: 0] += 1
                if e.endDate > day, e.startDate < day.addingTimeInterval(86400) { today.append(Self.map(e)) }
            }
        }
        state.today = today.sorted { $0.start < $1.start }
        model.weekCounts = counts
        evaluate()
    }

    /// Runs every 30 s: show the next event's live activity, fire time-to-leave alerts.
    func evaluate() {
        let prefs = CalendarPreferences.shared
        let now = Date()
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
}
