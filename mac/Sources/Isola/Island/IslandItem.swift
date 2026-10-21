import SwiftUI

enum SwipeDirection { case left, right, up, down }

/// Something shown in the island. Live activities persist until ended; notifications
/// and HUDs are transient and dismiss themselves.
struct IslandItem: Identifiable {
    enum Kind { case liveActivity, notification, hud }

    let id: String
    var kind: Kind
    /// Higher wins when several live activities run at once.
    var priority: Int = 0
    var leading: AnyView
    var trailing: AnyView
    /// Shown under the notch while quick-peeking (or always, if `alwaysPeek`).
    var peek: AnyView?
    var alwaysPeek = false
    /// Full panel when the island is expanded.
    var expanded: AnyView?
    var expandedSize = CGSize(width: 400, height: 180)
    /// Optional custom compact view; replaces the leading/trailing wings (e.g. lock screen).
    var onTap: (() -> Void)?
    var onOptionTap: (() -> Void)?
    var onSwipe: ((SwipeDirection) -> Bool)?
    var startedAt = Date()

    init<L: View, T: View>(
        id: String,
        kind: Kind,
        priority: Int = 0,
        @ViewBuilder leading: () -> L,
        @ViewBuilder trailing: () -> T
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.leading = AnyView(leading())
        self.trailing = AnyView(trailing())
    }

    func peek<V: View>(always: Bool = false, @ViewBuilder _ view: () -> V) -> IslandItem {
        var copy = self
        copy.peek = AnyView(view())
        copy.alwaysPeek = always
        return copy
    }

    func expanded<V: View>(size: CGSize = CGSize(width: 400, height: 180), @ViewBuilder _ view: () -> V) -> IslandItem {
        var copy = self
        copy.expanded = AnyView(view())
        copy.expandedSize = size
        return copy
    }

    func onTap(_ action: @escaping () -> Void) -> IslandItem {
        var copy = self
        copy.onTap = action
        return copy
    }

    func onOptionTap(_ action: @escaping () -> Void) -> IslandItem {
        var copy = self
        copy.onOptionTap = action
        return copy
    }

    /// Return true when the swipe was handled (otherwise the island applies its defaults).
    func onSwipe(_ action: @escaping (SwipeDirection) -> Bool) -> IslandItem {
        var copy = self
        copy.onSwipe = action
        return copy
    }
}
