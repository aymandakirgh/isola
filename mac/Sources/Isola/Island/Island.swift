import SwiftUI
import Observation

/// Island › Gestures, as `Island.swipe` reads them.
struct Gestures {
    var toggle = true, skip = true, dismiss = true, cycle = true
}

/// The island's state machine. Modules start/end live activities and post transient
/// notifications or HUDs; the view derives size, corners and content from this state.
@MainActor @Observable
final class Island {
    static let shared = Island()

    /// Island › Gestures, read at every swipe (the self-check's island sets its own).
    @ObservationIgnored var gestures: @MainActor () -> Gestures = {
        let p = Preferences.shared
        return Gestures(toggle: p.swipeToToggle, skip: p.swipeToSkip, dismiss: p.swipeToDismiss, cycle: p.swipeToCycle)
    }
    /// Island › Idle Activity: the item that opens with nothing running (nil for none), and whether
    /// it also stays in the compact island. `Modules` wires them to the media and calendar views after
    /// the island first draws, so they're observed: wiring them redraws it.
    var idleItem: @MainActor () -> IslandItem? = { nil }
    var idleKept: @MainActor () -> Bool = { false }

    private(set) var activities: [IslandItem] = []
    private(set) var transient: IslandItem?
    private(set) var expanded = false
    private(set) var peeking = false
    private(set) var peekCount = 0
    private(set) var hovering = false
    private(set) var pressed = false
    private(set) var activityIndex = 0
    /// Live activities swiped away, with the content key they had then (see `dismiss`).
    private(set) var dismissed: [String: String] = [:]
    /// The last live activity with a panel to end (Idle Activity › Most Recent).
    private(set) var lastEnded: IslandItem?
    /// Displays whose island is hidden for a fullscreen app/game or Mission Control (see Fullscreen.swift).
    var suppressed: Set<CGDirectDisplayID> = []

    @ObservationIgnored private var transientTimer: Timer?
    @ObservationIgnored private var transientAnimation: Animation?
    @ObservationIgnored private var peekTimer: Timer?
    @ObservationIgnored private var hoverExpandTimer: Timer?
    @ObservationIgnored private var restoreTimer: Timer?
    /// Set when the user cycles while expanded: collapsing then returns to the most important activity.
    @ObservationIgnored private var cycledWhileExpanded = false

    /// Live activities in rotation, most important first; swiped-away ones sit out.
    var sortedActivities: [IslandItem] {
        activities.filter { dismissed[$0.id] == nil }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.startedAt < $1.startedAt }
    }

    var currentActivity: IslandItem? {
        let list = sortedActivities
        return list.isEmpty ? nil : list[activityIndex % list.count]
    }

    /// What the island shows right now: a transient beats the live activity. With nothing
    /// running, the Idle Activity shows while it's open, and all the time when kept.
    var current: IslandItem? {
        if let item = transient ?? currentActivity { return item }
        return expanded || idleKept() ? idleItem() : nil
    }

    /// Duo mode: the other live activity, shown in a bubble beside the island.
    var secondary: IslandItem? { Preferences.shared.duo ? partner : nil }

    /// The most important other activity; none while expanded or while a transient shows.
    var partner: IslandItem? {
        guard transient == nil, !expanded, let shown = currentActivity else { return nil }
        return sortedActivities.first { $0.id != shown.id }
    }

    var isIdle: Bool { current == nil && !expanded }

    // MARK: - Live activities

    func start(_ item: IslandItem) {
        if replace(item) { return }
        let shown = currentActivity
        withAnimation(Springs.expand) {
            activities.append(item)
            announce(item, over: shown)
        }
    }

    /// Replace an activity's content without re-announcing it.
    func update(_ item: IslandItem) {
        if !replace(item) { start(item) }
    }

    /// New content for a running activity (it keeps its start time); false if it isn't running.
    /// A swiped-away activity whose content changed comes back like a new one.
    private func replace(_ item: IslandItem) -> Bool {
        guard let i = activities.firstIndex(where: { $0.id == item.id }) else { return false }
        var updated = item
        updated.startedAt = activities[i].startedAt
        activities[i] = updated
        if let key = dismissed[item.id], key != item.contentKey ?? "" {
            let shown = currentActivity
            withAnimation(Springs.expand) {
                dismissed[item.id] = nil
                announce(item, over: shown)
            }
        }
        return true
    }

    /// A new (or returning) activity takes the island unless something more important is showing.
    private func announce(_ item: IslandItem, over shown: IslandItem?) {
        show(shown.map { $0.priority > item.priority } == true ? shown?.id : item.id)
    }

    /// Point the island at an activity (nil: the most important one); an expanded island
    /// collapses if the newly shown item has nothing to expand into.
    private func show(_ id: String?) {
        activityIndex = id.flatMap { id in sortedActivities.firstIndex { $0.id == id } } ?? 0
        if expanded, current?.expanded == nil { expanded = false; cycledWhileExpanded = false }
    }

    func end(_ id: String) {
        guard let item = activities.first(where: { $0.id == id }) else { return }
        if item.expanded != nil { lastEnded = item }
        let shown = currentActivity?.id
        withAnimation(Springs.collapseActivity) {
            activities.removeAll { $0.id == id }
            dismissed[id] = nil
            show(shown == id ? nil : shown)
            if sortedActivities.isEmpty, transient == nil { expanded = false; peeking = false }
        }
    }

    /// Swipe up on a compact live activity: it leaves the rotation until it starts or updates
    /// with a different `contentKey` (e.g. the next track), or ends.
    func dismiss(_ id: String) {
        guard let item = activities.first(where: { $0.id == id }), dismissed[id] == nil else { return }
        let shown = currentActivity?.id
        withAnimation(Springs.collapseActivity) {
            dismissed[id] = item.contentKey ?? ""
            show(shown == id ? nil : shown)
            if sortedActivities.isEmpty, transient == nil { expanded = false; peeking = false }
        }
    }

    func isRunning(_ id: String) -> Bool { activities.contains { $0.id == id } }

    /// Swipe down / middle click: show the next live activity (false: there is no other).
    @discardableResult func cycle() -> Bool {
        let list = sortedActivities
        guard list.count > 1 else { return false }
        if expanded { cycledWhileExpanded = true }
        let next = list[(activityIndex + 1) % list.count].id
        withAnimation(Springs.expand) { show(next) }
        return true
    }

    /// Duo mode: clicking the bubble swaps the two activities.
    func swapDuo() {
        guard let other = secondary else { return }
        withAnimation(Springs.expand) { show(other.id) }
    }

    // MARK: - Transients (notifications and HUDs)

    /// `animation` and `collapse` spring a HUD in and out at its own speed (HUDs › Motion); nil uses the island's.
    func post(_ item: IslandItem, duration: TimeInterval? = nil, animation: Animation? = nil, collapse: Animation? = nil) {
        let seconds = duration ?? Preferences.shared.notificationDuration
        transientTimer?.invalidate()
        transientAnimation = collapse
        if transient?.id == item.id {
            transient = item  // same notification/HUD again: refresh content, extend timer
        } else {
            withAnimation(animation ?? Springs.expand) { transient = item }
        }
        transientTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { Island.shared.dismissTransient() }
        }
    }

    func dismissTransient() {
        transientTimer?.invalidate()
        guard transient != nil else { return }
        withAnimation(transientAnimation ?? Springs.collapseNotification) {
            transient = nil
            if sortedActivities.isEmpty { peeking = false }
        }
        setPressed(false)
    }

    // MARK: - Quick peek, expansion, hover

    func quickPeek(_ on: Bool, for duration: TimeInterval? = nil) {
        peekTimer?.invalidate()
        guard on != peeking, !(on && current?.peek == nil) else { return }
        withAnimation(on ? Springs.peekIn : Springs.peekOut) {
            peeking = on
            if on { peekCount &+= 1 }
        }
        if on, let duration {
            peekTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                MainActor.assumeIsolated { Island.shared.quickPeek(false) }
            }
        }
    }

    func setExpanded(_ on: Bool) {
        hoverExpandTimer?.invalidate()
        guard on != expanded, !(on && !canExpand) else { return }
        restoreTimer?.invalidate()
        haptic()
        withAnimation(on ? Springs.openPanel : Springs.collapseActivity) {
            expanded = on
            if on { peeking = false; hovering = false }
        }
        if on { cycledWhileExpanded = false; return }
        // Cycled while open: once collapsed, go back to the most important activity.
        guard cycledWhileExpanded else { return }
        cycledWhileExpanded = false
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.expanded else { return }
                withAnimation(Springs.expand) { self.show(nil) }
            }
        }
    }

    /// Only items with a panel expand (with nothing running, the Idle Activity's); with "Expand
    /// while inactive" off, idle ones (paused media) stay compact.
    private var canExpand: Bool {
        guard let item = current ?? idleItem(), item.expanded != nil else { return false }
        return Preferences.shared.expandWhileInactive || item.inactive?() != true
    }

    func setHovering(_ on: Bool) {
        guard on != hovering else { return }
        hoverExpandTimer?.invalidate()
        let delay = Preferences.shared.hoverExpandDelay
        if on, delay > 0, !expanded {
            hoverExpandTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { Island.shared.setExpanded(true) }
            }
        }
        if !on { setPressed(false) }
        if let item = current, item.peekOnHover, item.peek != nil, !expanded {
            hovering = on
            if on { haptic() }
            quickPeek(on)
            return
        }
        guard !peeking else { return }
        if on, !expanded { haptic() }
        withAnimation(on ? Springs.hoverIn : Springs.hoverOut) { hovering = on && !expanded }
    }

    func setPressed(_ on: Bool) {
        guard on != pressed else { return }
        withAnimation(Springs.press) { pressed = on }
    }

    // MARK: - Interaction

    func tap(option: Bool = false) {
        if option, let action = current?.onOptionTap { return action() }
        if let action = current?.onTap, !expanded { return action() }
        setExpanded(!expanded)
    }

    func swipe(_ direction: SwipeDirection) {
        let g = gestures()
        // A gesture switched off in Island › Gestures reaches neither the activity nor the island:
        // horizontal swipes are the media skip, swipe up on a compact activity dismisses it. An activity's
        // own swipe up is a dismissal too (a calendar event's, peeking or not): with that off, swipe up
        // only closes the panel, a peek or a notification.
        switch direction {
        case .left, .right: guard g.skip else { return }
        case .up where !expanded && !peeking && transient == nil: guard g.dismiss else { return }
        default: break
        }
        if direction != .up || g.dismiss, current?.onSwipe?(direction) == true { return haptic() }
        switch direction {
        case .down:
            if !expanded {
                if g.toggle { setExpanded(true) }
            } else if g.cycle, cycle() {
                haptic()
            }
        case .up:
            if expanded {
                if g.toggle { setExpanded(false) }
            } else if peeking {
                quickPeek(false)
                haptic()
            } else if transient != nil {
                dismissTransient()
                haptic()
            } else if let id = currentActivity?.id {
                dismiss(id)
                haptic()
            }
        case .left, .right: break
        }
    }

    /// A trackpad tap for the island's own motion (Island › Interaction › Haptic feedback).
    private func haptic() {
        guard Preferences.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: - Geometry

    var state: IslandState {
        IslandState(item: current, secondary: secondary, expanded: expanded, peeking: peeking, hovering: hovering, pressed: pressed, peekCount: peekCount)
    }

    /// Island size on a given screen for the current state.
    func size(in g: NotchGeometry) -> CGSize { Self.size(for: state, in: g) }
    func radii(in g: NotchGeometry) -> (top: CGFloat, bottom: CGFloat) { Self.radii(for: state, in: g) }

    nonisolated static func size(for s: IslandState, in g: NotchGeometry) -> CGSize {
        if s.expanded, let item = s.item, item.expanded != nil {
            return CGSize(width: max(item.expandedSize.width, g.activity.width), height: max(item.expandedSize.height, g.height))
        }
        guard let item = s.item else { return g.compact }
        return (s.peeking || item.alwaysPeek) && item.peek != nil ? g.peek : g.activity
    }

    /// Corner radii scale with the island height; the web demo uses 12 / 13 hovered / 13-19 peeking at 40pt.
    nonisolated static func radii(for s: IslandState, in g: NotchGeometry) -> (top: CGFloat, bottom: CGFloat) {
        let scale = g.height / 40
        let peek = (s.peeking || s.item?.alwaysPeek == true) && s.item?.peek != nil
        let (top, bottom): (CGFloat, CGFloat) =
            s.expanded && s.item?.expanded != nil ? (28 * scale, 32 * scale)
            : peek ? (13 * scale, 19 * scale)
            : s.hovering ? (13 * scale, 13 * scale)
            : (12 * scale, 12 * scale)
        return (g.attached ? 0 : top, bottom)
    }

    /// Notchless displays with no simulated notch hide the idle pill entirely.
    func visible(in g: NotchGeometry) -> Bool {
        !suppressed.contains(g.displayID) && !(isIdle && !g.hasNotch && !g.attached && !Preferences.shared.showIdlePill)
    }

    // MARK: - Self-check (`Isola --gallery`)

    /// Swipe-up dismissal, duo pairing, the restore after cycling, Island › Gestures switched off
    /// and the Idle Activity, on private instances.
    static func selfCheck() {
        let island = Island()
        var g = Gestures()
        island.gestures = { g }
        func item(_ id: String, _ priority: Int, key: String? = nil) -> IslandItem {
            IslandItem(id: id, kind: .liveActivity, priority: priority) { EmptyView() } trailing: { EmptyView() }
                .expanded { EmptyView() }
                .contentKey(key)
        }
        island.start(item("music", 10, key: "song 1"))
        island.start(item("timer", 5))
        precondition(island.current?.id == "music" && island.partner?.id == "timer", "most important shows, the other pairs")
        island.swipe(.up)
        precondition(island.current?.id == "timer" && island.partner == nil, "swipe up dismisses the compact activity")
        island.update(item("music", 10, key: "song 1"))
        precondition(island.current?.id == "timer", "same content: still dismissed")
        island.update(item("music", 10, key: "song 2"))
        precondition(island.current?.id == "music", "new content: back, and it takes the island")
        island.setExpanded(true)
        island.cycle()
        precondition(island.current?.id == "timer" && island.expanded, "cycling while expanded")
        island.setExpanded(false)
        precondition(island.current?.id == "timer", "the cycled item stays for a moment")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(island.current?.id == "music", "then the most important activity returns")

        // Island › Gestures, one switch at a time.
        g.cycle = false
        island.setExpanded(true)
        island.swipe(.down)
        precondition(island.current?.id == "music" && island.expanded, "swipe to cycle off: swipe down leaves the panel as it is")
        g.toggle = false
        island.swipe(.up)
        precondition(island.expanded, "swipe to open and close off: swipe up doesn't close")
        island.setExpanded(false)
        island.swipe(.down)
        precondition(!island.expanded, "…and swipe down doesn't open")
        g.dismiss = false
        island.swipe(.up)
        precondition(island.current?.id == "music", "swipe to dismiss off: the compact activity stays")
        island.post(IslandItem(id: "note", kind: .notification) { EmptyView() } trailing: { EmptyView() }, duration: 60)
        island.swipe(.up)
        precondition(island.transient == nil, "…but a notification still closes")
        var dismissals = 0
        island.start(item("event", 30).peek { EmptyView() }.onSwipe { direction in
            if direction == .up { dismissals += 1 }
            return direction == .up
        })
        island.quickPeek(true)
        island.swipe(.up)
        precondition(dismissals == 0 && !island.peeking, "…nor does a peeking activity's own swipe up (a calendar event's): only the peek closes")
        island.end("event")
        var skips = 0
        island.start(item("player", 20).onSwipe { direction in
            guard direction == .left || direction == .right else { return false }
            skips += 1
            return true
        })
        g.skip = false
        island.swipe(.right)
        precondition(skips == 0, "swipe to skip off: horizontal swipes don't reach the activity")
        g.skip = true
        island.swipe(.right)
        precondition(skips == 1, "on, they do")

        // Island › Idle Activity: with nothing running a tap or swipe down opens it; kept, it also stays compact.
        let quiet = Island()
        quiet.gestures = { Gestures() }
        var kept = false
        quiet.idleItem = { item("idle.calendar", 0) }
        quiet.idleKept = { kept }
        precondition(quiet.isIdle && quiet.current == nil, "nothing running: idle")
        quiet.tap()
        precondition(quiet.expanded && quiet.current?.id == "idle.calendar", "a tap opens the idle panel")
        quiet.swipe(.up)
        precondition(!quiet.expanded && quiet.isIdle, "swipe up closes it")
        quiet.swipe(.down)
        precondition(quiet.expanded && quiet.current?.id == "idle.calendar", "swipe down opens it too")
        quiet.setExpanded(false)
        kept = true
        precondition(quiet.current?.id == "idle.calendar" && !quiet.isIdle, "kept: it stays in the compact island")
        quiet.start(item("music", 10))
        precondition(quiet.current?.id == "music", "a live activity takes over")
        quiet.end("music")
        precondition(quiet.lastEnded?.id == "music" && quiet.current?.id == "idle.calendar", "and leaves Most Recent behind when it ends")
    }
}
