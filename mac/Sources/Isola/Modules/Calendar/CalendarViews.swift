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
    static let panelSize = CGSize(width: 400, height: 200)

    static func event(_ e: CalendarEvent) -> IslandItem { event(e, panel: LiveCalendarPanel()) }

    /// Upcoming event: colour dot + calendar glyph, countdown; the title peeks on hover.
    static func event<P: View>(_ e: CalendarEvent, panel: P) -> IslandItem {
        IslandItem(id: eventID, kind: .liveActivity, priority: 2) {
            EventLeading(color: e.calendarColor)
        } trailing: {
            CountdownText(to: e.start).padding(.trailing, 11)
        }
        .peek(onHover: true) { EventPeek(event: e) }
        .expanded(size: panelSize) { panel }
        .onSwipe { direction in
            // Swipe up dismisses this event (restore it from the expanded calendar).
            guard direction == .up, !Island.shared.expanded else { return false }
            CalendarSource.shared.dismiss(e.id)
            return true
        }
    }

    static func leave(_ e: CalendarEvent, now: Date) -> IslandItem {
        IslandItem(id: leaveID, kind: .notification) {
            Image(systemName: "car.fill").islandSymbol(15).foregroundStyle(Palette.amber).padding(.leading, 11)
        } trailing: {
            CountdownText(to: e.start).padding(.trailing, 11)
        }
        .peek(always: true) { LeavePeek(event: e) }
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

// MARK: - Wings

private struct EventLeading: View {
    var color: NSColor
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: color)).frame(width: 7, height: 7)
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

private struct EventPeek: View {
    var event: CalendarEvent
    var body: some View {
        Marquee {
            HStack(spacing: 4) {
                Circle().fill(Color(nsColor: event.calendarColor)).frame(width: 6, height: 6)
                Text(event.title).foregroundStyle(Palette.ink)
                Text("· \(CalendarText.time(event.start))\(event.location.map { " · \($0)" } ?? "")")
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
    var body: some View {
        Marquee {
            HStack(spacing: 4) {
                Text("Time to leave").foregroundStyle(Palette.amber)
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
            let progress = (snapshot ?? CalendarTimer.shared.snapshot)?.progress(at: context.date) ?? 0
            BatteryRing(level: progress, color: Palette.amber, size: 21, lineWidth: 2.5)
                .overlay(Image(systemName: "timer").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.amber))
        }
    }
}

private struct TimerCountdown: View {
    var snapshot: TimerSnapshot?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = (snapshot ?? CalendarTimer.shared.snapshot)?.remaining(at: context.date) ?? 0
            Text(CalendarText.clock(remaining))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Palette.amber).lineLimit(1).fixedSize()
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
        detail = w.precipitationChance.map { $0 >= 0.3 ? "Rain likely · \(Int(($0 * 100).rounded()))%" : "No rain expected" }
    }

    init(temperature: String, symbol: String, condition: String, detail: String?) {
        self.temperature = temperature
        self.symbol = symbol
        self.condition = condition
        self.detail = detail
    }
}

/// Reads the shared calendar/weather/timer state.
struct LiveCalendarPanel: View {
    var body: some View {
        let prefs = CalendarPreferences.shared
        TimelineView(.everyMinute) { context in
            CalendarPanel(
                events: CalendarState.shared.today,
                weekCounts: CalendarModel.shared.weekCounts,
                weather: prefs.weather ? WeatherSnapshot(WeatherState.shared) : nil,
                timer: CalendarTimer.shared.snapshot,
                dismissedCount: prefs.dismissed.count,
                lunar: prefs.lunar,
                now: context.date,
                colors: prefs.calendarColors,
                splitAllDay: prefs.splitAllDay,
                weatherOnEmptyDay: prefs.weatherOnEmptyDay
            )
        }
    }
}

/// The expanded calendar: month, week strip with event dots, today's agenda (or the
/// weather on an empty day) and timer presets. Pure: everything comes in as values.
struct CalendarPanel: View {
    var events: [CalendarEvent]
    var weekCounts: [Date: Int]
    var weather: WeatherSnapshot?
    var timer: TimerSnapshot?
    var dismissedCount: Int
    var lunar: Bool
    var now: Date
    var colors = true
    var splitAllDay = true
    var weatherOnEmptyDay = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: 34, alignment: .top)
            WeekStrip(counts: weekCounts, lunar: lunar, now: now).frame(height: 48)
            agenda.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 6)
            footer.frame(height: 24)
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 9)
        .frame(width: CalendarItems.panelSize.width, height: CalendarItems.panelSize.height, alignment: .top)
        .foregroundStyle(Palette.ink)
    }

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
        let allDay = splitAllDay ? events.filter(\.isAllDay) : []
        let upcoming = events.filter { (!splitAllDay || !$0.isAllDay) && $0.end > now }
        if upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !allDay.isEmpty { AllDayChips(events: allDay, now: now, colors: colors) }
                EmptyDay(weather: weatherOnEmptyDay ? weather : nil)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !allDay.isEmpty { AllDayChips(events: allDay, now: now, colors: colors) }
                ForEach(upcoming.prefix(allDay.isEmpty ? 2 : 1)) { EventRow(event: $0, now: now, colors: colors) }
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
    var lunar: Bool
    var now: Date

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = cal.date(byAdding: .day, value: offset, to: start)!
                let isToday = cal.isDate(day, inSameDayAs: today)
                let cell = DayCell(day: day, isToday: isToday, isPast: day < today, events: counts[day] ?? 0, lunar: lunar)
                if isToday {
                    Button(action: CalendarSource.openCalendarApp) { cell }.buttonStyle(.plain)
                } else {
                    cell
                }
            }
        }
    }
}

private struct DayCell: View {
    var day: Date
    var isToday: Bool
    var isPast: Bool
    var events: Int
    var lunar: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(CalendarText.weekdayInitial(day)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.muted)
            ZStack {
                if isToday { Circle().fill(Palette.ink).frame(width: 23, height: 23) }
                Text(CalendarText.dayNumber(day))
                    .font(.system(size: 13, weight: isToday ? .bold : .medium)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.black : isPast ? Palette.muted.opacity(0.6) : Palette.ink)
            }
            .frame(height: 23)
            if lunar {
                Text(CalendarText.lunarDay(day)).font(.system(size: 8, weight: .medium)).foregroundStyle(Palette.muted)
            } else {
                Circle().fill(events > 0 ? (isToday ? Palette.amber : Palette.muted) : .clear).frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct AllDayChips: View {
    var events: [CalendarEvent]
    var now: Date
    var colors: Bool
    var body: some View {
        HStack(spacing: 6) {
            ForEach(events.prefix(2)) { e in
                HStack(spacing: 4) {
                    Circle().fill(colors ? Color(nsColor: e.calendarColor) : Palette.muted).frame(width: 5, height: 5)
                    Text(e.title).lineLimit(1)
                    if let span = CalendarText.span(e, on: now) { Text(span).foregroundStyle(Palette.muted).fixedSize() }
                }
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            Text("All day").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
        }
    }
}

private struct EventRow: View {
    var event: CalendarEvent
    var now: Date
    var colors: Bool

    var body: some View {
        let started = event.start <= now
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(colors ? Color(nsColor: event.calendarColor) : Palette.muted).frame(width: 3, height: 27)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                let when = CalendarText.span(event, on: now) ?? (event.isAllDay ? "All day" : CalendarText.range(event.start, event.end))
                Text(when + (event.location.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(started ? "Now" : "in \(CalendarText.countdown(to: event.start, from: now))")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(started ? Palette.amber : Palette.muted)
        }
    }
}

private struct EmptyDay: View {
    var weather: WeatherSnapshot?
    var body: some View {
        HStack(spacing: 10) {
            if let weather {
                Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 26))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("No more events today").font(.system(size: 12.5, weight: .semibold))
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
                if calendar.authorized {
                    Label("Isola can read your calendars", systemImage: "checkmark.circle.fill")
                } else {
                    LabeledContent("Upcoming events need access to your calendars") {
                        Button("Allow Access…") { CalendarSource.shared.requestAccess() }
                    }
                }
            }
            Section("Upcoming events") {
                Toggle("Show upcoming events in the island", isOn: $prefs.liveActivity)
                Stepper("Appear \(prefs.leadMinutes) minutes before they start", value: $prefs.leadMinutes, in: 1...60)
                Toggle("Time to leave alerts for events with a location", isOn: $prefs.timeToLeave)
                Stepper("Alert \(prefs.leaveMinutes) minutes before", value: $prefs.leaveMinutes, in: 5...90, step: 5)
                    .disabled(!prefs.timeToLeave)
                Toggle("Show the date when nothing else is running", isOn: $prefs.idleActivity)
            }
            Section("Expanded calendar") {
                Toggle("Show declined events", isOn: $prefs.showDeclined)
                Toggle("Hide subscribed calendars", isOn: $prefs.excludeSubscribed)
                Toggle("Use calendar colours", isOn: $prefs.calendarColors)
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
                Picker("Units", selection: $prefs.weatherUnit) {
                    Text("Automatic").tag("auto")
                    Text("Celsius").tag("c")
                    Text("Fahrenheit").tag("f")
                }
                Toggle("Show the weather on days with no events left", isOn: $prefs.weatherOnEmptyDay)
            }
            .disabled(false)
        }
        .formStyle(.grouped)
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

    /// "4:12", "24:12", "1:04:12".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func range(_ start: Date, _ end: Date) -> String { "\(time(start)) – \(time(end))" }

    /// Multi-day events: "Day 1 of 3 · from 22:00", "Day 2 of 3", "Day 3 of 3 · until 07:10".
    /// nil for an event that starts and ends on the same day.
    static func span(_ e: CalendarEvent, on date: Date) -> String? {
        let days = e.days()
        guard days.count > 1, let i = days.firstIndex(of: Calendar.current.startOfDay(for: date)) else { return nil }
        let label = "Day \(i + 1) of \(days.count)"
        if e.isAllDay { return label }
        return i == 0 ? "\(label) · from \(time(e.start))" : i == days.count - 1 ? "\(label) · until \(time(e.end))" : label
    }
    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide)) }
    static func dayNumber(_ date: Date) -> String { String(Calendar.current.component(.day, from: date)) }
    static func weekdayInitial(_ date: Date) -> String { date.formatted(.dateTime.weekday(.narrow)) }

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
    }
}
