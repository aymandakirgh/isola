import SwiftUI
import Observation

/// The island's state machine. Modules start/end live activities and post transient
/// notifications or HUDs; the view derives size, corners and content from this state.
@MainActor @Observable
final class Island {
    static let shared = Island()

    private(set) var activities: [IslandItem] = []
    private(set) var transient: IslandItem?
    private(set) var expanded = false
    private(set) var peeking = false
    private(set) var hovering = false
    private(set) var pressed = false
    private(set) var activityIndex = 0
    /// Hidden while a fullscreen app/game or Mission Control is up (see Fullscreen.swift).
    var suppressed = false

    @ObservationIgnored private var transientTimer: Timer?
    @ObservationIgnored private var peekTimer: Timer?
    @ObservationIgnored private var hoverExpandTimer: Timer?

    var sortedActivities: [IslandItem] {
        activities.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.startedAt < $1.startedAt }
    }

    var currentActivity: IslandItem? {
        let list = sortedActivities
        return list.isEmpty ? nil : list[activityIndex % list.count]
    }

    /// What the island shows right now: a transient beats the live activity.
    var current: IslandItem? { transient ?? currentActivity }

    var isIdle: Bool { current == nil && !expanded }

    // MARK: - Live activities

    func start(_ item: IslandItem) {
        if let i = activities.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            updated.startedAt = activities[i].startedAt
            activities[i] = updated
            return
        }
        let shown = currentActivity
        withAnimation(Springs.expand) {
            activities.append(item)
            // A new activity takes the island unless something more important is showing.
            show(shown.map { $0.priority > item.priority } == true ? shown?.id : item.id)
        }
    }

    /// Point the island at an activity (nil: the most important one); an expanded island
    /// collapses if the newly shown item has nothing to expand into.
    private func show(_ id: String?) {
        activityIndex = id.flatMap { id in sortedActivities.firstIndex { $0.id == id } } ?? 0
        if expanded, current?.expanded == nil { expanded = false }
    }

    /// Replace an activity's content without re-announcing it.
    func update(_ item: IslandItem) {
        guard let i = activities.firstIndex(where: { $0.id == item.id }) else { return start(item) }
        var updated = item
        updated.startedAt = activities[i].startedAt
        activities[i] = updated
    }

    func end(_ id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        let shown = currentActivity?.id
        withAnimation(Springs.collapseActivity) {
            activities.removeAll { $0.id == id }
            show(shown == id ? nil : shown)
            if activities.isEmpty, transient == nil { expanded = false; peeking = false }
        }
    }

    func isRunning(_ id: String) -> Bool { activities.contains { $0.id == id } }

    /// Swipe down / middle click: show the next live activity.
    func cycle() {
        guard activities.count > 1 else { return }
        let next = sortedActivities[(activityIndex + 1) % activities.count].id
        withAnimation(Springs.expand) { show(next) }
    }

    // MARK: - Transients (notifications and HUDs)

    func post(_ item: IslandItem, duration: TimeInterval? = nil) {
        let seconds = duration ?? Preferences.shared.notificationDuration
        transientTimer?.invalidate()
        if transient?.id == item.id {
            transient = item  // same notification/HUD again: refresh content, extend timer
        } else {
            withAnimation(Springs.expand) { transient = item }
        }
        transientTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { Island.shared.dismissTransient() }
        }
    }

    func dismissTransient() {
        transientTimer?.invalidate()
        guard transient != nil else { return }
        withAnimation(Springs.collapseNotification) {
            transient = nil
            if activities.isEmpty { peeking = false }
        }
        setPressed(false)
    }

    // MARK: - Quick peek, expansion, hover

    func quickPeek(_ on: Bool, for duration: TimeInterval? = nil) {
        peekTimer?.invalidate()
        guard on != peeking, !(on && current?.peek == nil) else { return }
        withAnimation(on ? Springs.peekIn : Springs.peekOut) { peeking = on }
        if on, let duration {
            peekTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                MainActor.assumeIsolated { Island.shared.quickPeek(false) }
            }
        }
    }

    func setExpanded(_ on: Bool) {
        hoverExpandTimer?.invalidate()
        guard on != expanded, !(on && current?.expanded == nil) else { return }
        withAnimation(on ? Springs.openPanel : Springs.collapseActivity) {
            expanded = on
            if on { peeking = false; hovering = false }
        }
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
            quickPeek(on)
            return
        }
        guard !peeking else { return }
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
        if current?.onSwipe?(direction) == true { return }
        switch direction {
        case .down: expanded ? cycle() : setExpanded(true)
        case .up:
            if expanded { setExpanded(false) } else if peeking { quickPeek(false) } else if transient != nil { dismissTransient() }
        case .left, .right: break
        }
    }

    // MARK: - Geometry

    var state: IslandState {
        IslandState(item: current, expanded: expanded, peeking: peeking, hovering: hovering, pressed: pressed)
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
        !suppressed && !(isIdle && !g.hasNotch && !g.attached && !Preferences.shared.showIdlePill)
    }
}
