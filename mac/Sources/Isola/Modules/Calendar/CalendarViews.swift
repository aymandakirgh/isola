import AppKit
import SwiftUI

// MARK: - Island items

@MainActor
enum CalendarItems {
    static let eventID = "calendar.event"
    static let leaveID = "calendar.leave"
    static let timerID = "timer"
    static let timerDoneID = "timer.done"
    static let idleID = "calendar.idle"

    /// The expanded calendar; the month view's is taller (it stays inside the island's 300 pt window,
    /// a floating pill's top margin included).
    nonisolated static func panelSize(monthView: Bool) -> CGSize { CGSize(width: 400, height: monthView ? 290 : 200) }
    static var panelSize: CGSize { panelSize(monthView: CalendarPreferences.shared.monthView) }

    static func event(_ e: CalendarEvent) -> IslandItem {
        let prefs = CalendarPreferences.shared
        return event(e, panel: LiveCalendarPanel(), colors: prefs.calendarColors, timeLeft: !prefs.hideDuringEvents)
    }

    /// Upcoming event: colour dot + calendar glyph, the countdown and then the time left; the title
    /// peeks on hover. `size` pins the panel (gallery).
    static func event<P: View>(_ e: CalendarEvent, panel: P, colors: Bool = true, timeLeft: Bool = true, size: CGSize? = nil) -> IslandItem {
        IslandItem(id: eventID, kind: .liveActivity, priority: 2) {
            EventLeading(color: e.tint(colors))
        } trailing: {
            EventStatus(event: e, timeLeft: timeLeft).padding(.trailing, 11)
        }
        .peek(onHover: true) { EventPeek(event: e, tint: e.tint(colors)) }
        .expanded(size: size ?? panelSize) { panel }
        .onOptionTap { CalendarSource.shared.open(e) }
        .onSwipe { direction in
            // Swipe up dismisses this event (restore it from the expanded calendar).
            guard direction == .up, !Island.shared.expanded else { return false }
            CalendarSource.shared.dismiss(e.id)
            return true
        }
    }

    /// `travel` is the Apple Maps estimate, when there is one ("25m by car" in the peek).
    static func leave(_ e: CalendarEvent, now: Date, travel: TimeInterval? = nil) -> IslandItem {
        let mode = CalendarPreferences.shared.travelMode
        let trip = travel.map { "\(CalendarText.countdown(to: now.addingTimeInterval(max($0, 60)), from: now)) \(mode.phrase)" }
        return IslandItem(id: leaveID, kind: .notification) {
            Image(systemName: mode.symbol).islandSymbol(15).foregroundStyle(Palette.amber).padding(.leading, 11)
        } trailing: {
            CountdownText(to: e.start).padding(.trailing, 11)
        }
        .peek(always: true) { LeavePeek(event: e, trip: trip) }
        .expanded(size: panelSize) { LiveCalendarPanel() }
    }

    /// Running timer: draining ring + countdown. `snapshot` pins the values (gallery).
    static func timer(snapshot: TimerSnapshot? = nil) -> IslandItem {
        IslandItem(id: timerID, kind: .liveActivity, priority: 5) {
            TimerRing(snapshot: snapshot).padding(.leading, 10)
        } trailing: {
            TimerCountdown(snapshot: snapshot).padding(.trailing, 9)
        }
        .expanded(size: panelSize) { LiveCalendarPanel() }
        .onOptionTap { CalendarTimer.shared.togglePause() }
    }

    static func timerDone() -> IslandItem {
        IslandItem(id: timerDoneID, kind: .notification) {
            Image(systemName: "bell.fill").islandSymbol(15).foregroundStyle(Palette.amber).padding(.leading, 11)
        } trailing: {
            Image(systemName: "checkmark").islandSymbol(14).foregroundStyle(Palette.amber).padding(.trailing, 12)
        }
    }

    static func idle() -> IslandItem { idle(panel: LiveCalendarPanel(), nextEvent: nil) }

    /// Optional quiet activity: today's date, and the next event's countdown or the temperature.
    static func idle<P: View>(panel: P, nextEvent: CalendarEvent?) -> IslandItem {
        IslandItem(id: idleID, kind: .liveActivity, priority: -10) {
            DateBadge().padding(.leading, 10)
        } trailing: {
            IdleTrailing(pinned: nextEvent).padding(.trailing, 11)
        }
        .expanded(size: panelSize) { panel }
    }
}

// MARK: - Context menu

/// Right-click menus of the calendar's island items.
/// ponytail: a right-click monitor of this module's own, as the core has no context-menu hook on
/// IslandItem yet; once it does, each item hands these entries to it and `install()` goes.
@MainActor
enum CalendarMenu {
    /// The event activity: join its call (when it has a link), show it, dismiss it.
    static func entries(for e: CalendarEvent, meeting: URL?, app: String) -> [MenuEntry] {
        var list: [MenuEntry] = []
        if let meeting, let service = CalendarSource.service(of: meeting) {
            list.append(.action("Join \(service)", symbol: "video.fill") { NSWorkspace.shared.open(meeting) })
        }
        list.append(.action("Open in \(app)", symbol: "calendar") { CalendarSource.shared.show(e) })
        list += [.separator, .action("Dismiss Event", symbol: "xmark.circle") { CalendarSource.shared.dismiss(e.id) }]
        return list
    }

    /// The date and the timer: the calendar app.
    static func openApp(_ app: String) -> [MenuEntry] {
        [.action("Open in \(app)", symbol: "calendar") { CalendarSource.openCalendarApp() }]
    }

    /// The menu of what the compact island shows, when it is one of the calendar's items.
    static func current() -> [MenuEntry]? {
        let island = Island.shared
        guard !island.expanded, let id = island.current?.id else { return nil }
        switch id {
        case CalendarItems.eventID:
            return CalendarSource.shared.shown.map { entries(for: $0, meeting: CalendarSource.shared.meetingURL(for: $0), app: CalendarSource.appName) }
        case CalendarItems.idleID, CalendarItems.timerID:
            return openApp(CalendarSource.appName)
        default:
            return nil
        }
    }

    static func install() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            MainActor.assumeIsolated { popUp() } ? nil : event
        }
    }

    /// A right-click on the island: the menu at the pointer (true), or nothing to show.
    private static func popUp() -> Bool {
        let location = NSEvent.mouseLocation
        guard IslandWindows.shared.panels.contains(where: { $0.islandRect().contains(location) }), let entries = current() else { return false }
        let menu = NSMenu()
        for entry in entries { menu.addItem(StatusItem.item(for: entry)) }
        menu.popUp(positioning: nil, at: location, in: nil)
        return true
    }
}

// MARK: - Wings

extension CalendarEvent {
    /// The calendar's colour, or `neutral` with "Use calendar colours" off.
    func tint(_ colors: Bool, neutral: Color = Palette.muted) -> Color {
        colors ? Color(nsColor: calendarColor) : neutral
    }
}

extension [CalendarEvent] {
    /// The events on `day` (multi-day ones on each day they cover), in start order.
    func on(_ day: Date) -> [CalendarEvent] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return filter { $0.end > start && $0.start < end }
    }
}

private struct EventLeading: View {
    var color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Image(systemName: "calendar").islandSymbol(14)
        }
        .padding(.leading, 10)
    }
}

/// "8m", "1h 5m", "Now" — ticks every second.
private struct CountdownText: View {
    var to: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(CalendarText.countdown(to: to, from: context.date))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .lineLimit(1).fixedSize()
        }
    }
}

/// The event wing: the countdown to the start, then the time left ("25m" over "left"); "Now"
/// when hiding during events.
private struct EventStatus: View {
    var event: CalendarEvent
    var timeLeft: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if timeLeft, let left = CalendarText.timeLeft(event, at: context.date) {
                VStack(alignment: .trailing, spacing: -2) {
                    Text(left).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    Text("left").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            } else {
                Text(CalendarText.countdown(to: event.start, from: context.date))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
        }
    }
}

private struct EventPeek: View {
    var event: CalendarEvent
    var tint: Color
    var body: some View {
        // Under way, the end matters more than the start.
        let when = event.start <= Date() && event.end > Date() ? "until \(CalendarText.time(event.end))" : CalendarText.time(event.start)
        Marquee {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(event.title).foregroundStyle(Palette.ink)
                Text("· \(when)\(event.location.map { " · \($0)" } ?? "")")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 11)
    }
}

private struct LeavePeek: View {
    var event: CalendarEvent
    var trip: String?
    var body: some View {
        Marquee {
            HStack(spacing: 4) {
                Text("Time to leave").foregroundStyle(Palette.amber)
                if let trip { Text("· \(trip)").foregroundStyle(Palette.amber) }
                Text("· \(event.title)").foregroundStyle(Palette.ink)
                if let location = event.location { Text("· \(location)") }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 11)
    }
}

private struct TimerRing: View {
    var snapshot: TimerSnapshot?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let timer = snapshot ?? CalendarTimer.shared.snapshot
            BatteryRing(level: timer?.progress(at: context.date) ?? 0, color: Palette.amber, size: 21, lineWidth: 2.5)
                .overlay(Image(systemName: timer?.paused == nil ? "timer" : "pause.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.amber))
        }
    }
}

private struct TimerCountdown: View {
    var snapshot: TimerSnapshot?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let timer = snapshot ?? CalendarTimer.shared.snapshot
            Text(CalendarText.clock(timer?.remaining(at: context.date) ?? 0))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(timer?.paused == nil ? Palette.amber : Palette.muted).lineLimit(1).fixedSize()
        }
    }
}

private struct DateBadge: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.ink.opacity(0.85), lineWidth: 1.5)
                Text(CalendarText.dayNumber(context.date)).font(.system(size: 10, weight: .bold)).monospacedDigit()
            }
            .frame(width: 20, height: 18)
        }
    }
}

private struct IdleTrailing: View {
    var pinned: CalendarEvent?
    var body: some View {
        if let next = pinned ?? CalendarState.shared.next {
            CountdownText(to: next.start)
        } else if WeatherState.shared.available {
            Text(WeatherState.shared.displayTemperature).font(.system(size: 13, weight: .semibold))
        }
    }
}

// MARK: - Expanded calendar

struct WeatherSnapshot {
    var temperature: String
    var symbol: String
    var condition: String
    var detail: String?

    @MainActor init?(_ w: WeatherState) {
        guard w.available else { return nil }
        temperature = w.displayTemperature
        symbol = w.symbol
        condition = w.condition
        detail = w.precipitationDetail ?? w.precipitationChance.map { _ in "No rain expected" }
    }

    init(temperature: String, symbol: String, condition: String, detail: String?) {
        self.temperature = temperature
        self.symbol = symbol
        self.condition = condition
        self.detail = detail
    }
}

/// The dots under days with events: none, one, or up to three in their calendars' colours.
enum DayDots { case none, plain, colored }

/// Reads the shared calendar/weather/timer state. A day picked in it is forgotten once it closes.
struct LiveCalendarPanel: View {
    var body: some View {
        let prefs = CalendarPreferences.shared
        let model = CalendarModel.shared
        TimelineView(.everyMinute) { context in
            CalendarPanel(
                events: model.events,
                weekCounts: model.weekCounts,
                weekColors: model.weekColors,
                weather: prefs.weather ? WeatherSnapshot(WeatherState.shared) : nil,
                timer: CalendarTimer.shared.snapshot,
                dismissedCount: prefs.dismissed.count,
                lunar: prefs.lunar,
                now: context.date,
                colors: prefs.calendarColors,
                splitAllDay: prefs.splitAllDay,
                weatherOnEmptyDay: prefs.weatherOnEmptyDay,
                monthView: prefs.monthView,
                dots: prefs.eventIndicators ? (prefs.coloredIndicators ? .colored : .plain) : .none,
                selectedDay: model.selectedDay
            )
        }
        .onDisappear { model.selectedDay = nil }
    }
}

/// The expanded calendar: month, week strip (or the whole month) with event dots, today's agenda
/// (tomorrow's once today is done, or a picked day's) and timer presets. Pure: everything comes in
/// as values.
struct CalendarPanel: View {
    /// Every loaded event: today's, tomorrow's and the rest of the days on show.
    var events: [CalendarEvent]
    var weekCounts: [Date: Int]
    var weekColors: [Date: [NSColor]] = [:]
    var weather: WeatherSnapshot?
    var timer: TimerSnapshot?
    var dismissedCount: Int
    var lunar: Bool
    var now: Date
    var colors = true
    var splitAllDay = true
    var weatherOnEmptyDay = true
    var monthView = false
    var dots = DayDots.colored
    /// A day picked in the strip or grid; its events replace today's.
    var selectedDay: Date? = nil

    var body: some View {
        let size = CalendarItems.panelSize(monthView: monthView)
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: 34, alignment: .top)
            if monthView {
                MonthGrid(counts: weekCounts, colors: weekColors, dots: dots, now: now, selected: selectedDay)
            } else {
                WeekStrip(counts: weekCounts, colors: weekColors, dots: dots, lunar: lunar, now: now, selected: selectedDay).frame(height: 48)
            }
            agenda.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 6)
            footer.frame(height: 24)
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 9)
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(Palette.ink)
    }

    private var today: Date { Calendar.current.startOfDay(for: now) }

    // Left and right of the top band only: a hardware notch covers its centre.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(CalendarText.month(now)).font(.system(size: 15, weight: .bold))
                if lunar { Text(CalendarText.lunarHeader(now)).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted) }
            }
            Spacer()
            if let weather {
                HStack(spacing: 5) {
                    Image(systemName: weather.symbol).symbolRenderingMode(.multicolor)
                    Text(weather.temperature)
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    @ViewBuilder private var agenda: some View {
        if let day = selectedDay, day != today {
            dayAgenda(day)
        } else {
            todayAgenda
        }
    }

    /// Today: all-day chips, then what's left of the day; once it's done, tomorrow.
    @ViewBuilder private var todayAgenda: some View {
        let todays = events.on(today)
        let allDay = splitAllDay ? todays.filter(\.isAllDay) : []
        let upcoming = todays.filter { (!splitAllDay || !$0.isAllDay) && $0.end > now }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let tomorrows = events.on(tomorrow)
        VStack(alignment: .leading, spacing: 6) {
            if !allDay.isEmpty { AllDayChips(events: allDay, now: now, colors: colors) }
            if !upcoming.isEmpty {
                EventRows(events: upcoming, limit: allDay.isEmpty ? 2 : 1, now: now, colors: colors)
            } else if !tomorrows.isEmpty {
                Heading(text: "Tomorrow · \(CalendarText.events(tomorrows.count))")
                EventRows(events: tomorrows, limit: 2, now: now, colors: colors, trailing: .tomorrow, day: tomorrow)
            } else {
                EmptyDay(title: todays.contains { !$0.isAllDay } ? "No more events today" : "Your day is clear", weather: weatherOnEmptyDay ? weather : nil)
            }
        }
    }

    /// A picked day: its events, or a line saying it has none.
    @ViewBuilder private func dayAgenda(_ day: Date) -> some View {
        let list = events.on(day)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        VStack(alignment: .leading, spacing: 6) {
            Heading(text: list.isEmpty ? CalendarText.dayTitle(day) : "\(CalendarText.dayTitle(day)) · \(CalendarText.events(list.count))")
            if list.isEmpty {
                Text(day < today ? "No events" : "This day is clear").font(.system(size: 12.5, weight: .semibold))
            } else {
                EventRows(events: list, limit: 2, now: now, colors: colors, trailing: day == tomorrow ? .tomorrow : .none, day: day)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            if let timer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(CalendarText.clock(timer.remaining(at: context.date)))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.amber)
                }
                Spacer()
                PanelButton(title: timer.paused == nil ? "Pause" : "Resume") { CalendarTimer.shared.togglePause() }
                PanelButton(title: "Stop") { CalendarTimer.shared.stop() }
            } else {
                Text("Timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                ForEach([1, 5, 15, 25], id: \.self) { minutes in
                    PanelButton(title: "\(minutes)m") { CalendarTimer.shared.start(Double(minutes) * 60) }
                }
                Spacer()
                if dismissedCount > 0 {
                    PanelButton(title: "Restore \(dismissedCount)") { CalendarPreferences.shared.dismissed = [] }
                }
            }
        }
    }
}

private struct WeekStrip: View {
    var counts: [Date: Int]
    var colors: [Date: [NSColor]]
    var dots: DayDots
    var lunar: Bool
    var now: Date
    var selected: Date?

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = cal.date(byAdding: .day, value: offset, to: start)!
                DayButton(day: day, today: today, selected: selected) {
                    DayCell(day: day, today: today, selected: selected, events: counts[day] ?? 0, colors: colors[day] ?? [], dots: dots, lunar: lunar)
                }
            }
        }
    }
}

/// "Always show month view": six weeks from the one holding the 1st; other months' days are faint.
private struct MonthGrid: View {
    var counts: [Date: Int]
    var colors: [Date: [NSColor]]
    var dots: DayDots
    var now: Date
    var selected: Date?

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let start = CalendarSource.monthGrid(for: now).start
        let month = cal.component(.month, from: now)
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(CalendarText.weekdayInitial(cal.date(byAdding: .day, value: i, to: start)!))
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 1)
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let day = cal.date(byAdding: .day, value: week * 7 + i, to: start)!
                        DayButton(day: day, today: today, selected: selected) {
                            DayCell(
                                day: day, today: today, selected: selected, events: counts[day] ?? 0, colors: colors[day] ?? [], dots: dots,
                                outside: cal.component(.month, from: day) != month, compact: true
                            )
                        }
                    }
                }
            }
        }
    }
}

/// A day of the strip or grid: picks it (its events show below; again goes back to today). Today
/// opens the calendar app, or with another day picked, comes back to today.
private struct DayButton<Label: View>: View {
    var day: Date
    var today: Date
    var selected: Date?
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            let model = CalendarModel.shared
            if day == today {
                if selected != nil { model.selectedDay = nil } else { CalendarSource.openCalendarApp() }
            } else {
                model.selectedDay = selected == day ? nil : day
            }
        } label: {
            label
        }
        .buttonStyle(.plain)
    }
}

private struct DayCell: View {
    var day: Date
    var today: Date
    var selected: Date?
    var events: Int
    var colors: [NSColor]
    var dots: DayDots
    var lunar = false
    /// Another month's day in the month grid.
    var outside = false
    /// The month grid's smaller cell; its weekday initials sit in a row of their own.
    var compact = false

    var body: some View {
        let isToday = day == today
        let size: CGFloat = compact ? 17 : 23
        VStack(spacing: compact ? 0 : 2) {
            if !compact {
                Text(CalendarText.weekdayInitial(day)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            ZStack {
                if isToday {
                    Circle().fill(Palette.ink).frame(width: size, height: size)
                } else if day == selected {
                    Circle().stroke(Palette.ink.opacity(0.75), lineWidth: 1.25).frame(width: size - 1, height: size - 1)
                }
                Text(CalendarText.dayNumber(day))
                    .font(.system(size: compact ? 11 : 13, weight: isToday ? .bold : .medium)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.black : outside ? Palette.faint : day < today ? Palette.muted.opacity(0.6) : Palette.ink)
            }
            .frame(height: size)
            if lunar, !compact {
                Text(CalendarText.lunarDay(day)).font(.system(size: 8, weight: .medium)).foregroundStyle(Palette.muted)
            } else {
                let dot: CGFloat = compact ? 3 : 4
                HStack(spacing: 2) {
                    if events > 0, dots == .colored, !colors.isEmpty {
                        ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                            Circle().fill(Color(nsColor: color)).frame(width: dot, height: dot)
                        }
                    } else if events > 0, dots != .none {
                        Circle().fill(isToday ? Palette.amber : Palette.muted).frame(width: dot, height: dot)
                    }
                }
                .frame(height: dot)
                .padding(.top, compact ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Today's all-day events as chips: two, then one with "+2 more all-day", then all of them
/// collapsed into "3 all-day events", whichever fits.
private struct AllDayChips: View {
    var events: [CalendarEvent]
    var now: Date
    var colors: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(2)
            row(1)
            if events.count > 1 { MutedChip(text: CalendarText.allDayEvents(events.count)) } else { row(1) }
        }
    }

    private func row(_ shown: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(events.prefix(shown)) { chip($0) }
            if events.count > shown {
                MutedChip(text: CalendarText.moreAllDay(events.count - shown))
            } else {
                Text("All day").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func chip(_ e: CalendarEvent) -> some View {
        HStack(spacing: 4) {
            Circle().fill(e.tint(colors)).frame(width: 5, height: 5)
            Text(e.title).lineLimit(1)
            if let span = CalendarText.span(e, on: now) { Text(span).foregroundStyle(Palette.muted).fixedSize() }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

private struct MutedChip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// Up to `limit` rows, as many as fit, and a muted "2 more events" line for the rest.
private struct EventRows: View {
    var events: [CalendarEvent]
    var limit: Int
    var now: Date
    var colors: Bool
    var trailing = EventRow.Trailing.countdown
    /// The day the rows are listed under (multi-day spans count from it).
    var day: Date?

    var body: some View {
        ViewThatFits(in: .vertical) {
            if limit > 1 { rows(limit) }
            rows(1)
        }
    }

    private func rows(_ shown: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(events.prefix(shown)) { EventRow(event: $0, now: now, colors: colors, trailing: trailing, day: day ?? now) }
            if events.count > shown {
                Text(CalendarText.more(events.count - shown))
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.muted)
                    .padding(.leading, 11)
            }
        }
    }
}

private struct EventRow: View {
    /// Today's rows count down ("in 2h", "25m left"); tomorrow's say "TMRW"; another day's, nothing.
    enum Trailing { case countdown, tomorrow, none }
    var event: CalendarEvent
    var now: Date
    var colors: Bool
    var trailing = Trailing.countdown
    var day: Date

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.tint(colors)).frame(width: 3, height: 27)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                let when = CalendarText.span(event, on: day) ?? (event.isAllDay ? "All day" : CalendarText.range(event.start, event.end))
                Text(when + (event.location.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            switch trailing {
            case .countdown:
                let started = event.start <= now
                Text(started ? CalendarText.timeLeft(event, at: now).map { "\($0) left" } ?? "Now" : "in \(CalendarText.countdown(to: event.start, from: now))")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(started ? Palette.amber : Palette.muted)
            case .tomorrow:
                Text("TMRW").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            case .none:
                EmptyView()
            }
        }
    }
}

/// A muted line naming the day (or tomorrow) above its events.
private struct Heading: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.muted).lineLimit(1)
    }
}

private struct EmptyDay: View {
    var title: String
    var weather: WeatherSnapshot?
    var body: some View {
        HStack(spacing: 10) {
            if let weather {
                Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 26))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let weather {
                    Text("\(weather.temperature) · \(weather.condition)").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    if let detail = weather.detail {
                        Text(detail).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }
}

private struct PanelButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct CalendarSettingsView: View {
    @Bindable var prefs = CalendarPreferences.shared
    var calendar = CalendarState.shared
    var weather = WeatherState.shared

    var body: some View {
        Form {
            Section("Calendar access") {
                PermissionRow(permission: Permission.calendar) { CalendarSource.shared.tick() }
            }
            Section {
                Toggle("Show upcoming events in the island", isOn: $prefs.liveActivity)
                Stepper("Appear \(prefs.leadMinutes) minutes before they start", value: $prefs.leadMinutes, in: 1...60)
                Toggle("Hide during events", isOn: $prefs.hideDuringEvents)
                Picker("Quick peek", selection: $prefs.peekTiming) {
                    ForEach(PeekTiming.allCases) { Text($0.title).tag($0) }
                }
                seconds("Peek for", $prefs.peekDuration, in: 1...8).disabled(prefs.peekTiming == .off)
                Toggle("Show the date when nothing else is running", isOn: $prefs.idleActivity)
                Toggle("Time to leave alerts for events with a location", isOn: $prefs.timeToLeave)
                Group {
                    Picker("Travel by", selection: $prefs.travelMode) {
                        ForEach(TravelMode.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Add \(prefs.leaveBuffer) minutes to the travel time", value: $prefs.leaveBuffer, in: 0...30, step: 5)
                    Stepper("Without a travel time, alert \(prefs.leaveMinutes) minutes before", value: $prefs.leaveMinutes, in: 5...90, step: 5)
                    seconds("Alert stays for", $prefs.leaveDuration, in: 3...30)
                }
                .disabled(!prefs.timeToLeave)
            } header: {
                Text("Upcoming events")
            } footer: {
                // Never asks for location itself: the Weather section's location row does.
                Text(Weather.shared.locationAuthorized
                    ? "Time to leave uses the Apple Maps travel time from your current location."
                    : "Time to leave uses travel time once Isola can use your location (Weather › Location access); until then it alerts a fixed time before.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Display") {
                Toggle("Show declined events", isOn: $prefs.showDeclined)
                Toggle("Hide subscribed calendars", isOn: $prefs.excludeSubscribed)
                Toggle("Use calendar colours", isOn: $prefs.calendarColors)
                Toggle("Always show month view", isOn: $prefs.monthView)
                Toggle("Show event dots", isOn: $prefs.eventIndicators)
                Toggle("Colour event dots by calendar", isOn: $prefs.coloredIndicators).disabled(!prefs.eventIndicators)
                Toggle("Show all-day events separately", isOn: $prefs.splitAllDay)
                Toggle("Show lunar dates", isOn: $prefs.lunar)
                Picker("Clicking today opens", selection: $prefs.openWith) {
                    Text("Calendar").tag("calendar")
                    if CalendarSource.isInstalled("fantastical") { Text("Fantastical").tag("fantastical") }
                    if CalendarSource.isInstalled("notion") { Text("Notion Calendar").tag("notion") }
                }
                LabeledContent("Dismissed events") {
                    Button(prefs.dismissed.isEmpty ? "Restore" : "Restore \(prefs.dismissed.count)") { prefs.dismissed = [] }
                        .disabled(prefs.dismissed.isEmpty)
                }
            }
            Section("Sounds") {
                Toggle("Play hourly chime", isOn: $prefs.hourlyChime)
                Toggle("Play sound on calendar event", isOn: $prefs.eventSound)
                Toggle("Play sound on alerts", isOn: $prefs.notificationSound)
            }
            if calendar.authorized {
                Section("Calendars") {
                    ForEach(CalendarSource.shared.calendars(), id: \.calendarIdentifier) { cal in
                        Toggle(isOn: Binding(
                            get: { !prefs.excludedCalendars.contains(cal.calendarIdentifier) },
                            set: { on in
                                prefs.excludedCalendars.removeAll { $0 == cal.calendarIdentifier }
                                if !on { prefs.excludedCalendars.append(cal.calendarIdentifier) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: cal.color ?? .systemBlue)).frame(width: 8, height: 8)
                                Text(cal.title)
                            }
                        }
                    }
                }
            }
            Section("Weather") {
                Toggle("Show weather", isOn: $prefs.weather)
                LabeledContent("Location", value: weather.place.isEmpty ? "Not set" : weather.place)
                HStack {
                    TextField("City", text: $prefs.weatherCity, prompt: Text("e.g. Bologna"))
                    Button("Set") { Task { await Weather.shared.setCity(prefs.weatherCity) } }
                }
                Button("Use Current Location") { Weather.shared.useCurrentLocation() }
                PermissionRow(permission: LocationPermission())
                Picker("Units", selection: $prefs.weatherUnit) {
                    Text("Automatic").tag("auto")
                    Text("Celsius").tag("c")
                    Text("Fahrenheit").tag("f")
                }
                Toggle("Show the weather on days with no events left", isOn: $prefs.weatherOnEmptyDay)
            }
        }
        .formStyle(.grouped)
    }

    /// A slider of whole seconds (snapping without a row of tick marks) with its value.
    private func seconds(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
                Text("\(Int(value.wrappedValue)) s").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
        }
    }
}

// MARK: - Text

enum CalendarText {
    /// "8m", "1h 5m", "2h", "Now".
    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "Now" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Time left in an event under way ("25m"); nil before it starts and once it's over, and for
    /// zero-length and multi-day events.
    static func timeLeft(_ e: CalendarEvent, at now: Date) -> String? {
        guard e.start <= now, e.end > now, e.end.timeIntervalSince(e.start) < 86400 else { return nil }
        return countdown(to: e.end, from: now)
    }

    /// "1 more event", "3 more events" under the rows that fit.
    static func more(_ n: Int) -> String { "\(n) more event\(n == 1 ? "" : "s")" }
    /// A day's summary: "1 event", "3 events".
    static func events(_ n: Int) -> String { "\(n) event\(n == 1 ? "" : "s")" }
    /// The chip after the all-day chips that fit.
    static func moreAllDay(_ n: Int) -> String { "+\(n) more all-day" }
    /// All of them collapsed into one chip.
    static func allDayEvents(_ n: Int) -> String { "\(n) all-day event\(n == 1 ? "" : "s")" }

    /// "4:12", "24:12", "1:04:12".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func range(_ start: Date, _ end: Date) -> String { "\(time(start)) – \(time(end))" }
    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide)) }
    static func dayNumber(_ date: Date) -> String { String(Calendar.current.component(.day, from: date)) }
    static func weekdayInitial(_ date: Date) -> String { date.formatted(.dateTime.weekday(.narrow)) }
    /// A picked day's heading: "Wednesday 23".
    static func dayTitle(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide).day()) }

    /// Multi-day events: "Day 1 of 3 · from 22:00", "Day 2 of 3", "Day 3 of 3 · until 07:10".
    /// nil for an event that starts and ends on the same day.
    static func span(_ e: CalendarEvent, on date: Date) -> String? {
        let days = e.days()
        guard days.count > 1, let i = days.firstIndex(of: Calendar.current.startOfDay(for: date)) else { return nil }
        let label = "Day \(i + 1) of \(days.count)"
        if e.isAllDay { return label }
        return i == 0 ? "\(label) · from \(time(e.start))" : i == days.count - 1 ? "\(label) · until \(time(e.end))" : label
    }

    // Chinese lunisolar calendar ("lunar year support").
    private static let chinese = Calendar(identifier: .chinese)
    private static let lunarDays = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
    private static let lunarMonths = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]

    /// Day label under the week strip; the 1st of a lunar month shows the month instead.
    static func lunarDay(_ date: Date) -> String {
        let c = chinese.dateComponents([.month, .day], from: date)
        guard let month = c.month, let day = c.day else { return "" }
        return day == 1 ? lunarMonths[month - 1] : lunarDays[day - 1]
    }

    /// e.g. "丙午年 九月初一".
    static func lunarHeader(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = chinese
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = "U年"
        let c = chinese.dateComponents([.month, .day], from: date)
        guard let month = c.month, let day = c.day else { return f.string(from: date) }
        return "\(f.string(from: date)) \(lunarMonths[month - 1])\(lunarDays[day - 1])"
    }

    /// Runs with the gallery (`Isola --gallery`).
    static func selfCheck() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        assert(countdown(to: now.addingTimeInterval(8 * 60), from: now) == "8m")
        assert(countdown(to: now.addingTimeInterval(65 * 60), from: now) == "1h 5m")
        assert(countdown(to: now.addingTimeInterval(-30), from: now) == "Now")
        assert(clock(252) == "4:12")
        assert(clock(3852) == "1:04:12")
        // 2026-02-17 is the first day of the Chinese new year (丙午).
        let newYear = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 2, day: 17, hour: 12).date!
        assert(lunarDay(newYear) == "正月")
        assert(lunarHeader(newYear).hasPrefix("丙午年"))
        // Time left: under way only, and never for zero-length or multi-day events.
        func event(_ from: Double, _ to: Double) -> CalendarEvent {
            CalendarEvent(id: "t", title: "T", start: now.addingTimeInterval(from * 60), end: now.addingTimeInterval(to * 60), calendarColor: .systemBlue)
        }
        precondition(timeLeft(event(-20, 25), at: now) == "25m" && timeLeft(event(5, 50), at: now) == nil && timeLeft(event(-50, -5), at: now) == nil
            && timeLeft(event(0, 0), at: now) == nil && timeLeft(event(-60, 2 * 1440), at: now) == nil, "time left")
        precondition(more(1) == "1 more event" && more(3) == "3 more events" && events(1) == "1 event" && events(2) == "2 events", "event counts")
        precondition(moreAllDay(2) == "+2 more all-day" && allDayEvents(1) == "1 all-day event" && allDayEvents(3) == "3 all-day events", "all-day counts")
    }
}
