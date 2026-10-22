import SwiftUI

/// Every feature module plugs in here.
@MainActor
enum Modules {
    static func start() {
        IdleActivities.start()
        CoreDemo.start()
        MediaModule.start()
        SystemModule.start()
        HUDModule.start()
        CalendarModule.start()
        LockScreenModule.start()
        SettingsModule.start()
    }

    static func registerGallery() {
        CoreDemo.gallery()
        MediaModule.gallery()
        SystemModule.gallery()
        HUDModule.gallery()
        CalendarModule.gallery()
        LockScreenModule.gallery()
        SettingsModule.gallery()
    }
}

/// Island › Idle Activity: the panel a click, hover-expand or swipe down opens with nothing
/// running, built from the media and calendar views. Forced, its wings stay in the compact island.
@MainActor
enum IdleActivities {
    /// The player beside the calendar, under a band that keeps a hardware notch clear of both.
    static let duoSize = CGSize(width: 780, height: 224)
    private static let playerSize = CGSize(width: 420, height: 162)

    static func start() {
        Island.shared.idle = { item(Preferences.shared.idleActivity, lastEnded: Island.shared.lastEnded).map { ($0, Preferences.shared.forceIdleActivity) } }
        // Calendar's "Show the date when nothing else is running" became Idle Activity › Calendar, kept in the island.
        let calendar = CalendarPreferences.shared
        if calendar.idleActivity {
            Preferences.shared.idleActivity = .calendar
            Preferences.shared.forceIdleActivity = true
            calendar.idleActivity = false
        }
    }

    static func item(_ choice: IdleActivity, lastEnded: IslandItem?) -> IslandItem? {
        switch choice {
        case .none: nil
        case .calendar: calendar()
        case .nowPlaying: nowPlaying()
        case .duo: duo()
        case .mostRecent: recent(lastEnded)
        }
    }

    /// Today's date and the next event (or the temperature), opening the calendar.
    static func calendar() -> IslandItem { idle("calendar", as: CalendarItems.idle()) }

    /// The player as it was left: its artwork and the paused track, or "Not Playing". `state`
    /// stands in for the shared one (gallery).
    static func nowPlaying(_ state: NowPlayingState? = nil) -> IslandItem {
        let state = state ?? .shared
        return IslandItem(id: "idle.nowPlaying", kind: .liveActivity) {
            WingArtwork(state: state, ui: .shared).padding(.leading, 9)
        } trailing: {
            if state.hasTrack { MediaTrailing(state: state).padding(.trailing, 9) }
        }
        .expanded(size: playerSize) { IdlePlayer(state: state) }
    }

    /// The artwork with the next event's countdown; open, the player and the calendar side by side.
    static func duo(_ state: NowPlayingState? = nil) -> IslandItem {
        let state = state ?? .shared
        var item = IslandItem(id: "idle.duo", kind: .liveActivity) {
            WingArtwork(state: state, ui: .shared).padding(.leading, 9)
        } trailing: {
            EmptyView()
        }
        item.trailing = CalendarItems.idle().trailing
        return item.expanded(size: duoSize) {
            HStack(spacing: 0) {
                IdlePlayer(state: state).frame(width: duoSize.width - CalendarItems.panelSize.width, height: playerSize.height)
                LiveCalendarPanel()
            }
            .padding(.top, duoSize.height - CalendarItems.panelSize.height)
        }
    }

    /// The last activity that ended: the player for media, the calendar for an event or a timer,
    /// any other one as it was. Nothing ended yet: the calendar.
    static func recent(_ ended: IslandItem?) -> IslandItem {
        guard let ended else { return calendar() }
        switch ended.id {
        case "media": return nowPlaying()
        case CalendarItems.eventID, CalendarItems.timerID, CalendarItems.idleID: return calendar()
        default: return idle("recent.\(ended.id)", as: ended)
        }
    }

    /// An activity's wings and panel under an `idle.` id, so it never passes for the running one.
    private static func idle(_ name: String, as source: IslandItem) -> IslandItem {
        var item = IslandItem(id: "idle.\(name)", kind: .liveActivity) { EmptyView() } trailing: { EmptyView() }
        (item.leading, item.trailing, item.expanded, item.expandedSize) = (source.leading, source.trailing, source.expanded, source.expandedSize)
        return item
    }

    static func selfCheck() {
        let ended = { (id: String) in IslandItem(id: id, kind: .liveActivity) { EmptyView() } trailing: { EmptyView() }.expanded { EmptyView() } }
        precondition(item(.none, lastEnded: nil) == nil, "idle: none opens nothing")
        precondition(item(.duo, lastEnded: nil)?.expandedSize == duoSize, "idle: the duo panel is the widest")
        precondition(recent(ended("media")).id == "idle.nowPlaying" && recent(ended(CalendarItems.timerID)).id == "idle.calendar",
                     "idle: Most Recent opens the player after media, the calendar after a timer")
        precondition(recent(nil).id == "idle.calendar" && recent(ended("demo")).id == "idle.recent.demo", "idle: the calendar first, other activities as they were")
        precondition(duoSize.width + 60 <= IslandPanel.envelope.width, "idle: the island's window fits the duo panel")
    }
}

/// The idle player: the last track's player, or "Not Playing" once its source has gone.
struct IdlePlayer: View {
    var state = NowPlayingState.shared

    var body: some View {
        if state.hasTrack {
            ExpandedPlayer(state: state, ui: .shared)
        } else {
            HStack(spacing: 14) {
                ArtworkImage(image: nil, size: 58, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not Playing").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Play something in Music, Spotify or a browser.").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A sample item exercising the core (wings, peek, expanded, right-click menu) — `isolactl demo`.
@MainActor
enum CoreDemo {
    static func item(id: String = "demo") -> IslandItem {
        IslandItem(id: id, kind: .liveActivity) {
            Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).padding(.leading, 12)
        } trailing: {
            Text("Hi").font(.system(size: 13, weight: .semibold)).padding(.trailing, 12)
        }
        .peek { Text("Isola core demo · quick peek").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
        .expanded { Text("Expanded").font(.system(size: 20, weight: .bold)) }
        .contextMenu {
            [
                .action("Hide Until It Changes", symbol: "eye.slash") { Island.shared.dismiss(id) },
                .separator,
                .action("End Demo", symbol: "xmark.circle") { Island.shared.end(id) },
            ]
        }
    }

    static func start() {
        // `demo id=other` adds a second activity (duo mode); `key` is the content key a swipe-up
        // dismissal waits on; `inactive=1` marks it idle like paused media.
        Debug.on("demo") { args in
            let id = args["id"] ?? "demo"
            if args["off"] != nil { return Island.shared.end(id) }
            let inactive = args["inactive"] == "1"
            Island.shared.start(item(id: id).contentKey(args["key"]).inactive { inactive })
        }
        Debug.on("activity.dismiss") { args in
            if let id = args["id"] ?? Island.shared.currentActivity?.id { Island.shared.dismiss(id) }
        }
        Debug.on("duo.swap") { _ in Island.shared.swapDuo() }
        Debug.on("island.state") { _ in
            let island = Island.shared
            Debug.reply(
                "current=\(island.current?.id ?? "none") secondary=\(island.secondary?.id ?? "none") rotation=\(island.sortedActivities.map(\.id)) "
                    + "dismissed=\(island.dismissed.keys.sorted()) hiddenOn=\(island.suppressed.sorted()) expanded=\(island.expanded) "
                    + "idle=\(Preferences.shared.idleActivity.rawValue)\(Preferences.shared.forceIdleActivity ? "+kept" : "") lastEnded=\(island.lastEnded?.id ?? "none")"
            )
        }
    }

    /// The island over a dark wallpaper with the settings `Gallery.island` doesn't take: the accent
    /// colour (hover and press edge, outlines) and General › Progressive blur.
    private static func shot(
        _ name: String, _ state: IslandState, outline: OutlineStyle = .none, accent: Color? = nil, blur: Bool? = nil,
        size override: CGSize? = nil, geometry g: NotchGeometry = .pillPreview
    ) {
        let size = override ?? Island.size(for: state, in: g)
        Gallery.add(name, size: CGSize(width: max(size.width + 120, 420), height: size.height + g.topMargin + 40)) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.11, green: 0.1, blue: 0.16)], startPoint: .top, endPoint: .bottom)
                IslandBody(state: state, size: size, radii: Island.radii(for: state, in: g), geometry: g, outline: outline, accent: accent, blur: blur)
                    .scaleEffect(state.pressed ? 0.94 : state.hovering ? 1.075 : 1, anchor: .top)
                    .padding(.top, g.topMargin)
            }
        }
    }

    static func gallery() {
        IslandWindows.selfCheck()
        Island.selfCheck()
        IdleActivities.selfCheck()
        Fullscreen.selfCheck()
        MarqueeModel.selfCheck()
        Gallery.island("core-idle-notch", item: nil, geometry: .notchPreview)
        Gallery.island("core-activity-pill", item: item())
        Gallery.island("core-activity-notch", item: item(), geometry: .notchPreview)
        Gallery.island("core-hover", item: item(), hovering: true)
        Gallery.island("core-peek", item: item(), peeking: true)
        Gallery.island("core-expanded", item: item(), expanded: true)

        let ui = MediaUI()
        ui.offscreen = true
        let music = MediaActivity.item(state: SimulatedPlayer.sampleState(index: 0, playing: true), ui: ui)
        let timer = CalendarItems.timer(snapshot: TimerSnapshot(end: Date().addingTimeInterval(252), duration: 300))
        for (suffix, g) in [("pill", NotchGeometry.pillPreview), ("notch", NotchGeometry.notchPreview)] {
            // Outline styles (over a dark wallpaper), and duo mode with the timer in the bubble.
            Gallery.island("core-outline-colored-\(suffix)", item: music, outline: .colored, geometry: g)
            Gallery.island("core-outline-compact-\(suffix)", item: item(), outline: .compact, geometry: g)
            Gallery.island("core-outline-contrast-\(suffix)", item: item(), outline: .contrast, geometry: g)
            Gallery.island("core-duo-\(suffix)", item: music, secondary: timer, geometry: g)
        }
        Gallery.island("core-outline-compact-expanded", item: item(), expanded: true, outline: .compact)
        Gallery.island("core-outline-contrast-expanded", item: music, expanded: true, outline: .contrast, geometry: .notchPreview)
        Gallery.island("core-duo-outline", item: music, secondary: timer, outline: .contrast, geometry: .notchPreview)
        // Mid-spring: the player is still shorter than its content, which blurs into the bottom edge…
        Gallery.island("core-edge-blur", item: music, expanded: true, size: CGSize(width: 420, height: 134))
        // …or, with Progressive blur off, is cut there.
        shot("core-edge-blur-off", IslandState(item: music, expanded: true), blur: false, size: CGSize(width: 420, height: 134))

        // Use accent color: the hover and press edge, and the Compact and Contrast outlines.
        let accent = Color(nsColor: .controlAccentColor)
        shot("core-accent-hover", IslandState(item: item(), hovering: true), accent: accent)
        shot("core-accent-pressed-notch", IslandState(item: item(), pressed: true), accent: accent, geometry: .notchPreview)
        shot("core-accent-outline-contrast-notch", IslandState(item: item()), outline: .contrast, accent: accent, geometry: .notchPreview)
        shot("core-accent-outline-compact", IslandState(item: item()), outline: .compact, accent: accent)
        shot("core-accent-duo-outline", IslandState(item: music, secondary: timer), outline: .contrast, accent: accent, geometry: .notchPreview)

        // Idle Activity: each panel open (nothing playing, or a paused track), and kept in the compact island.
        let paused = SimulatedPlayer.sampleState(index: 0, playing: false)
        Gallery.island("core-idle-calendar-expanded-notch", item: IdleActivities.calendar(), expanded: true, geometry: .notchPreview)
        Gallery.island("core-idle-nowplaying-expanded", item: IdleActivities.nowPlaying(), expanded: true)
        Gallery.island("core-idle-nowplaying-paused-expanded", item: IdleActivities.nowPlaying(paused), expanded: true)
        Gallery.island("core-idle-duo-expanded", item: IdleActivities.duo(), expanded: true)
        Gallery.island("core-idle-duo-expanded-notch", item: IdleActivities.duo(paused), expanded: true, geometry: .notchPreview)
        Gallery.island("core-idle-kept-calendar-pill", item: IdleActivities.calendar())
        Gallery.island("core-idle-kept-nowplaying-notch", item: IdleActivities.nowPlaying(), geometry: .notchPreview)
        Gallery.island("core-idle-kept-duo-notch", item: IdleActivities.duo(paused), geometry: .notchPreview)
        Gallery.island("core-idle-recent-demo-expanded", item: IdleActivities.recent(item()), expanded: true)

        // The demo's right-click menu, drawn like the menu bar menu.
        Gallery.add("core-context-menu", size: CGSize(width: 300, height: 130), hosted: true) {
            StatusMenuMock(entries: item().contextMenu?() ?? []).background(Color(nsColor: .windowBackgroundColor))
        }

        // Whole General and Island pages (the settings window crops them).
        Gallery.add("core-general-settings", size: CGSize(width: 520, height: 1280)) {
            GeneralPage(nav: SettingsNav()).background(Color(nsColor: .windowBackgroundColor))
        }
        Gallery.add("core-island-settings", size: CGSize(width: 520, height: 1360)) {
            IslandPage().background(Color(nsColor: .windowBackgroundColor))
        }
        // The marquee resting left-aligned, then mid-scroll with both edges soft (blurred, or only faded).
        for (name, clock, blur) in [("core-marquee-rest", 0.5, true), ("core-marquee-scrolling", 3.0, true), ("core-marquee-scrolling-noblur", 3.0, false)] {
            Gallery.add(name, size: CGSize(width: 300, height: 56), hosted: true) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.62), Color(red: 0.42, green: 0.24, blue: 0.7)], startPoint: .top, endPoint: .bottom)
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black).frame(width: 250, height: 36)
                    Marquee(clock: clock, blur: blur) {
                        Text("Isola core demo · a title long enough to scroll")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 6)
                    }
                    .frame(width: 230, height: 16)
                }
            }
        }
    }
}
