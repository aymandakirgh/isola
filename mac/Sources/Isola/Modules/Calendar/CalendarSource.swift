import AppKit
import EventKit

/// EventKit → `CalendarState`, plus the event live activity and time-to-leave alerts.
/// Never prompts on its own: access is requested only from the settings button.
@MainActor
final class CalendarSource {
    static let shared = CalendarSource()
    private var store = EKEventStore()
    /// The EventKit events behind this week's `CalendarEvent`s (links, notes, places).
    private var ekEvents: [String: EKEvent] = [:]
    private var ticker: Timer?
    /// Fires at the followed event's next edge (its start, then its end), between ticks.
    private var edgeTimer: Timer?
    /// Events already announced (title peeked, sound played) → their end: each one is announced once,
    /// across launches too, so logging back in during an event stays quiet.
    private var announced = UserDefaults.standard.dictionary(forKey: "calendar.announced") as? [String: Date] ?? [:] {
        didSet { UserDefaults.standard.set(announced, forKey: "calendar.announced") }
    }
    private var leaveNotified: Set<String> = []
    /// The event the live activity follows (its right-click menu acts on it).
    private(set) var shown: CalendarEvent?

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

    /// Access can be granted elsewhere (onboarding, System Settings, the settings' permission
    /// row once its prompt is answered): reload when it flips.
    func tick() {
        guard authorized != CalendarState.shared.authorized else { return evaluate() }
        store = EKEventStore()  // a store created before access was granted can stay empty
        reload()
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
        let range = Self.range(for: day, monthView: prefs.monthView)
        var events = model.debugEvents
        ekEvents = [:]

        if authorized {
            let calendars = store.calendars(for: .event).filter {
                !prefs.excludedCalendars.contains($0.calendarIdentifier) && !(prefs.excludeSubscribed && $0.type == .subscription)
            }
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
            let found = calendars.isEmpty ? [] : store.events(matching: predicate).filter { prefs.showDeclined || !Self.declined($0) }
            for e in found {
                let event = Self.map(e)
                ekEvents[event.id] = e
                events.append(event)
            }
        }
        events.sort { $0.start < $1.start }
        // Multi-day events are listed on every day they cover, and dotted on each of them.
        state.today = events.filter { $0.end > day && $0.start < tomorrow }
        model.events = events
        model.weekCounts = Self.counts(events, in: range)
        model.weekColors = Self.colors(events, in: range)
        leaveNotified.formIntersection(state.today.map(\.id))
        evaluate()
    }

    /// The days loaded: the week and tomorrow (the week's last day has a tomorrow too), or with
    /// the month view the whole 6-week grid as well.
    nonisolated static func range(for day: Date, monthView: Bool, calendar cal: Calendar = .current) -> DateInterval {
        let start = cal.startOfDay(for: day)
        let week = cal.dateInterval(of: .weekOfYear, for: start) ?? DateInterval(start: start, duration: 7 * 86400)
        var range = DateInterval(start: week.start, end: max(week.end, cal.date(byAdding: .day, value: 2, to: start)!))
        if monthView {
            let grid = monthGrid(for: start, calendar: cal)
            range = DateInterval(start: min(range.start, grid.start), end: max(range.end, grid.end))
        }
        return range
    }

    /// The month view's 6×7 days: from the start of the week holding the 1st.
    nonisolated static func monthGrid(for day: Date, calendar cal: Calendar = .current) -> DateInterval {
        let first = cal.dateInterval(of: .month, for: day)?.start ?? cal.startOfDay(for: day)
        let start = cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        return DateInterval(start: start, end: cal.date(byAdding: .day, value: 42, to: start)!)
    }

    /// Start of day → events on it, for the week strip.
    static func counts(_ events: [CalendarEvent], in week: DateInterval) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for e in events { for day in e.days(in: week) { counts[day, default: 0] += 1 } }
        return counts
    }

    /// Start of day → up to 3 different calendar colours among its events, in start order.
    static func colors(_ events: [CalendarEvent], in range: DateInterval) -> [Date: [NSColor]] {
        func key(_ c: NSColor) -> String {
            guard let s = c.usingColorSpace(.sRGB) else { return c.description }
            return String(format: "%.2f %.2f %.2f", s.redComponent, s.greenComponent, s.blueComponent)
        }
        var colors: [Date: [NSColor]] = [:]
        for e in events {
            for day in e.days(in: range) {
                let list = colors[day, default: []]
                guard list.count < 3, !list.contains(where: { key($0) == key(e.calendarColor) }) else { continue }
                colors[day] = list + [e.calendarColor]
            }
        }
        return colors
    }

    /// The event the live activity follows at `now` among `events` (today's, by start, none
    /// dismissed): one that started under 5 minutes ago ("Now"), else the next to start within
    /// `lead`, else, unless hiding during events, the latest to start of those under way. All-day
    /// events have nothing to count to, and one running a day or more isn't followed past its start.
    nonisolated static func followed(_ events: [CalendarEvent], now: Date, lead: TimeInterval, hideDuringEvents: Bool) -> CalendarEvent? {
        let timed = events.filter { !$0.isAllDay && $0.start <= now.addingTimeInterval(lead) }
        let grace = now.addingTimeInterval(-5 * 60)
        if let starting = timed.first(where: { $0.start <= now && $0.start > grace }) { return starting }
        if let next = timed.first(where: { $0.start > now }) { return next }
        guard !hideDuringEvents else { return nil }
        return timed.last { $0.end > now && $0.end.timeIntervalSince($0.start) < 86400 }
    }

    /// `announced` with `event` added when it is announced now: on appearing, or with the start peek
    /// at its start, and only the first time. Nil when it isn't. Events over before today drop out.
    nonisolated static func announcing(_ event: CalendarEvent, now: Date, timing: PeekTiming, announced: [String: Date]) -> [String: Date]? {
        guard timing != .start || now >= event.start, announced[event.id] == nil else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        var kept = announced.filter { $0.value > today }
        kept[event.id] = event.end
        return kept
    }

    /// Runs every 30 s (and at the followed event's start and end): show the event's live
    /// activity, peek and chime as set, fire time-to-leave alerts.
    func evaluate() {
        let prefs = CalendarPreferences.shared
        let now = Date()
        let candidates = CalendarState.shared.today.filter { !prefs.dismissed.contains($0.id) }
        shown = prefs.liveActivity
            ? Self.followed(candidates, now: now, lead: Double(prefs.leadMinutes) * 60, hideDuringEvents: prefs.hideDuringEvents) : nil
        edgeTimer?.invalidate()
        if let event = shown {
            Island.shared.start(CalendarItems.event(event))
            // First appearance (or the start, with the start peek): the title peeks and the sound plays.
            if let updated = Self.announcing(event, now: now, timing: prefs.peekTiming, announced: announced) {
                announced = updated
                if prefs.peekTiming != .off { peek() }
                if prefs.eventSound { CalendarSounds.event() }
            }
            let edge = [event.start, prefs.hideDuringEvents ? event.start.addingTimeInterval(5 * 60) : event.end].filter { $0 > now }.min()
            if let edge {
                let timer = Timer(fire: edge.addingTimeInterval(0.5), interval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated { CalendarSource.shared.evaluate() }
                }
                RunLoop.main.add(timer, forMode: .common)
                edgeTimer = timer
            }
        } else {
            Island.shared.end(CalendarItems.eventID)
        }

        guard prefs.timeToLeave else { return }
        for e in CalendarState.shared.today where e.start > now && !e.isAllDay && !leaveNotified.contains(e.id) {
            // A place to get to: a location that is a video-call link needs no travel.
            guard let location = e.location, !location.isEmpty, Self.meetingURL(in: [location]) == nil else { continue }
            let travel = TravelTime.shared.estimate(for: e, place: ekEvents[e.id]?.structuredLocation?.geoLocation, now: now)
            let buffer = Double(prefs.leaveBuffer) * 60, fallback = Double(prefs.leaveMinutes) * 60
            if TravelTime.isTimeToLeave(now: now, start: e.start, travel: travel, buffer: buffer, fallback: fallback) {
                leaveNotified.insert(e.id)
                postLeave(e, now: now, travel: travel)
                break
            }
        }
    }

    private func peek() {
        if Island.shared.current?.id == CalendarItems.eventID { Island.shared.quickPeek(true, for: CalendarPreferences.shared.peekDuration) }
    }

    /// A time-to-leave alert: it stays as long as set, with the alert sound if that's on.
    func postLeave(_ e: CalendarEvent, now: Date, travel: TimeInterval?) {
        let prefs = CalendarPreferences.shared
        Island.shared.post(CalendarItems.leave(e, now: now, travel: travel), duration: prefs.leaveDuration)
        if prefs.notificationSound { CalendarSounds.alert() }
    }

    func dismiss(_ id: String) {
        CalendarPreferences.shared.dismissed.append(id)
    }

    /// Option-click on an event: join its video call, else show it.
    func open(_ e: CalendarEvent) {
        if !join(e) { show(e) }
    }

    /// Opens the event's video call; false when it has none.
    @discardableResult func join(_ e: CalendarEvent) -> Bool {
        guard let url = meetingURL(for: e) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Shows the event in the calendar app chosen in settings (Calendar opens the event itself).
    func show(_ e: CalendarEvent) {
        if let ek = ekEvents[e.id], CalendarPreferences.shared.openWith == "calendar", let url = Self.calendarLink(ek) {
            NSWorkspace.shared.open(url)
        } else {
            Self.openCalendarApp()  // Fantastical and Notion Calendar have no reliable link to one event
        }
    }

    /// The video-call link in the event's URL, location or notes.
    func meetingURL(for e: CalendarEvent) -> URL? {
        let ek = ekEvents[e.id]
        return Self.meetingURL(in: [ek?.url?.absoluteString, e.location, ek?.notes])
    }

    /// Video-call hosts, and the service each one is.
    private static let meetingHosts: [(host: String, service: String)] = [
        ("zoom.us", "Zoom"), ("zoomgov.com", "Zoom"), ("meet.google.com", "Google Meet"), ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"), ("webex.com", "Webex"), ("facetime.apple.com", "FaceTime"), ("whereby.com", "Whereby"),
        ("meet.jit.si", "Jitsi Meet"), ("chime.aws", "Amazon Chime"), ("gotomeeting.com", "GoTo Meeting"), ("around.co", "Around"),
    ]

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first video-call link in an event's URL, location or notes.
    static func meetingURL(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            for match in linkDetector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                guard let url = match.url, service(of: url) != nil else { continue }
                return url
            }
        }
        return nil
    }

    /// "Zoom", "Google Meet"… for a video-call link.
    static func service(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return meetingHosts.first { host == $0.host || host.hasSuffix("." + $0.host) }?.service
    }

    /// Calendar.app's link to an event; a recurring one also names the occurrence (UTC unless all-day).
    private static func calendarLink(_ e: EKEvent) -> URL? {
        guard let id = e.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var occurrence = ""
        if e.hasRecurrenceRules {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            if !e.isAllDay { f.timeZone = TimeZone(identifier: "UTC") }
            occurrence = "/" + f.string(from: e.startDate)
        }
        return URL(string: "ical://ekevent\(occurrence)/\(id)?method=show&options=more")
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

    /// The app `openCalendarApp()` opens, by name: the chosen one if it's installed, else Calendar.
    static var appName: String {
        let choice = CalendarPreferences.shared.openWith
        guard choice != "calendar", isInstalled(choice) else { return "Calendar" }
        return choice == "fantastical" ? "Fantastical" : "Notion Calendar"
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

    /// Runs with the gallery (`Isola --gallery`): meeting links, the followed event, loaded days
    /// and multi-day splitting.
    static func selfCheck() {
        let zoom = meetingURL(in: [nil, "Studio 3", "Join: https://us02web.zoom.us/j/123?pwd=x"])
        precondition(zoom?.host == "us02web.zoom.us" && zoom.flatMap(service(of:)) == "Zoom", "Zoom link, named")
        precondition(meetingURL(in: ["https://meet.google.com/abc-defg-hij"]).flatMap(service(of:)) == "Google Meet")
        precondition(meetingURL(in: ["Agenda: https://docs.google.com/d/1", "Via Roma 12"]) == nil)

        let cal = Calendar.current
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func at(_ days: Int, _ hours: Double) -> Date { cal.date(byAdding: .day, value: days, to: day)!.addingTimeInterval(hours * 3600) }
        func event(_ start: Date, _ end: Date, allDay: Bool = false, id: String = "check", color: NSColor = .systemBlue) -> CalendarEvent {
            CalendarEvent(id: id, title: "Check", start: start, end: end, calendarColor: color, isAllDay: allDay)
        }

        // The followed event: "Now" for 5 minutes beats the next one; then the next one beats one
        // under way; under way, it stays to its end unless hiding during events.
        let standup = event(at(0, 9), at(0, 9.5), id: "standup"), review = event(at(0, 9 + 10.0 / 60), at(0, 10), id: "review")
        func followed(_ hours: Double, hide: Bool = false) -> String? {
            Self.followed([standup, review], now: at(0, hours), lead: 10 * 60, hideDuringEvents: hide)?.id
        }
        precondition(followed(8.5) == nil && followed(8.9) == "standup", "appears 10 minutes before")
        precondition(followed(9.05) == "standup", "Now for 5 minutes, even with the next one near")
        precondition(followed(9.1) == "review" && followed(9.2) == "review", "then the next one to start")
        precondition(followed(9.3) == "review" && followed(9.6) == "review" && followed(10.1) == nil, "under way, the latest to start, until it ends")
        precondition(followed(9.2, hide: true) == "review" && followed(9.3, hide: true) == nil, "hiding during events: 5 minutes of Now")
        precondition(Self.followed([event(at(-1, 9), at(1, 9))], now: at(0, 12), lead: 600, hideDuringEvents: false) == nil, "multi-day events aren't followed")
        precondition(Self.followed([event(at(0, 9), at(0, 9))], now: at(0, 9.05), lead: 600, hideDuringEvents: false) != nil, "zero-length: Now for 5 minutes")
        precondition(Self.followed([event(at(0, 0), at(1, 0), allDay: true)], now: at(0, 9), lead: 600, hideDuringEvents: false) == nil, "all-day events")
        // Announced once: A (9:00–10:00) on appearing, then B (9:30–9:45); A coming back at 9:45 stays quiet.
        let a = event(at(0, 9), at(0, 10), id: "a"), b = event(at(0, 9.5), at(0, 9.75), id: "b")
        let both = announcing(a, now: at(0, 8.9), timing: .appear, announced: [:]).flatMap { announcing(b, now: at(0, 9.5), timing: .appear, announced: $0) }
        precondition(both?.count == 2 && announcing(a, now: at(0, 9.76), timing: .appear, announced: both ?? [:]) == nil, "each event announced once")
        precondition(announcing(a, now: at(0, 8.9), timing: .start, announced: [:]) == nil && announcing(a, now: at(0, 9), timing: .start, announced: [:]) != nil,
            "the start peek waits for the start")
        precondition(announcing(event(at(1, 9), at(1, 10), id: "c"), now: at(1, 8.9), timing: .appear, announced: both ?? [:])?.keys.sorted() == ["c"],
            "yesterday's announced events drop out")

        // Loaded days: the week and tomorrow; the month view's 6 weeks around the 1st.
        let sunday = cal.dateInterval(of: .weekOfYear, for: day)!.end.addingTimeInterval(-3600)
        precondition(range(for: sunday, monthView: false).end == cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: sunday))!, "the week's last day loads tomorrow")
        let grid = monthGrid(for: day)
        let monthStart = cal.dateInterval(of: .month, for: day)!
        precondition(grid.duration > 41 * 86400 && grid.start <= monthStart.start && grid.end >= monthStart.end
            && cal.component(.weekday, from: grid.start) == cal.firstWeekday, "6×7 grid from the week holding the 1st")
        precondition(range(for: day, monthView: true).start <= grid.start && range(for: day, monthView: true).end >= grid.end, "month view loads the grid")
        // Coloured dots: up to 3 distinct colours a day, in start order.
        let palette: [NSColor] = [.systemRed, .systemBlue, .systemRed, .systemGreen, .systemOrange]
        let dotted = colors(palette.enumerated().map { event(at(0, Double(8 + $0.offset)), at(0, Double(8 + $0.offset) + 0.5), color: $0.element) }, in: DateInterval(start: at(0, 0), end: at(1, 0)))
        precondition(dotted[at(0, 0)] == [.systemRed, .systemBlue, .systemGreen], "3 distinct calendar colours")
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
