import AppKit
import SwiftUI

/// Borderless panel at the top of a screen that hosts the island. It is larger than
/// the island (room to expand) and lets clicks through everywhere except the island.
final class IslandPanel: NSPanel {
    static let envelope = CGSize(width: 720, height: 300)
    let screenID: CGDirectDisplayID
    private(set) var geometry: NotchGeometry

    @MainActor init(screen: NSScreen) {
        screenID = screen.displayID
        geometry = NotchGeometry.of(screen)
        super.init(contentRect: Self.frame(on: screen), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        applyPreferences()
        contentView = NSHostingView(rootView: IslandView(geometry: geometry))
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func frame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - envelope.width / 2, y: screen.frame.maxY - envelope.height,
            width: envelope.width, height: envelope.height
        )
    }

    @MainActor func relayout(on screen: NSScreen) {
        geometry = NotchGeometry.of(screen)
        setFrame(Self.frame(on: screen), display: true)
        (contentView as? NSHostingView<IslandView>)?.rootView = IslandView(geometry: geometry)
        applyPreferences()
    }

    @MainActor func applyPreferences() {
        sharingType = Preferences.shared.hideFromScreenCapture ? .none : .readOnly
    }

    /// The island's current rect in screen coordinates (plus a little slop for hover).
    @MainActor func islandRect(slop: CGFloat = 4) -> NSRect {
        let island = Island.shared
        guard island.visible(in: geometry) else { return .zero }
        let size = island.size(in: geometry)
        return NSRect(
            x: frame.midX - size.width / 2 - slop, y: frame.maxY - geometry.topMargin - size.height - slop,
            width: size.width + slop * 2, height: size.height + geometry.topMargin + slop * 2
        )
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }
}

/// Owns one panel per target screen and routes the mouse: hover, press, click,
/// two-finger swipes, middle click and click-outside-to-collapse.
@MainActor
final class IslandWindows {
    static let shared = IslandWindows()
    private(set) var panels: [IslandPanel] = []
    private var monitors: [Any] = []
    private var scrollAccumulator = CGSize.zero
    private var scrollLocked = false

    func start() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { IslandWindows.shared.refresh() } }
        installMonitors()
    }

    /// Screens that get an island, per preferences.
    func targetScreens() -> [NSScreen] {
        let p = Preferences.shared
        let screens = NSScreen.screens
        if p.allDisplays { return screens }
        switch p.preferredDisplay {
        case "main": return NSScreen.main.map { [$0] } ?? []
        case "builtin": return [screens.first(where: \.isBuiltIn) ?? screens.first].compactMap { $0 }
        case "auto":
            // Prefer a screen with a notch, else the main screen.
            return [screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main].compactMap { $0 }
        default:
            return [screens.first(where: { $0.localizedName == p.preferredDisplay }) ?? NSScreen.main].compactMap { $0 }
        }
    }

    func refresh() {
        let targets = targetScreens()
        let ids = Set(targets.map(\.displayID))
        for panel in panels where !ids.contains(panel.screenID) { panel.orderOut(nil) }
        panels.removeAll { !ids.contains($0.screenID) }
        for screen in targets {
            if let panel = panels.first(where: { $0.screenID == screen.displayID }) {
                panel.relayout(on: screen)
            } else {
                panels.append(IslandPanel(screen: screen))
            }
        }
    }

    private func panel(at point: NSPoint) -> IslandPanel? {
        panels.first { $0.islandRect().contains(point) }
    }

    func updatePointer(_ location: NSPoint = NSEvent.mouseLocation) {
        let over = panel(at: location)
        for p in panels { p.ignoresMouseEvents = p !== over }
        Island.shared.setHovering(over != nil)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moves) { _ in
            MainActor.assumeIsolated { IslandWindows.shared.updatePointer() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moves) { e in
            MainActor.assumeIsolated { IslandWindows.shared.updatePointer() }
            return e
        } as Any)
        // Clicking anywhere else closes the expanded island.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            MainActor.assumeIsolated {
                if Island.shared.expanded, IslandWindows.shared.panel(at: NSEvent.mouseLocation) == nil {
                    Island.shared.setExpanded(false)
                }
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .otherMouseDown, .scrollWheel]) { e in
            MainActor.assumeIsolated { IslandWindows.shared.handle(e) }
        } as Any)
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard panel(at: NSEvent.mouseLocation) != nil else { return e }
        let island = Island.shared
        switch e.type {
        case .leftMouseDown:
            island.setPressed(true)
        case .leftMouseUp:
            island.setPressed(false)
            // Controls inside the expanded panel handle their own clicks.
            if !island.expanded { island.tap(option: e.modifierFlags.contains(.option)) }
        case .otherMouseDown where e.buttonNumber == 2:
            island.cycle()
        case .scrollWheel:
            handleScroll(e)
        default: break
        }
        return e
    }

    /// The way the fingers moved, whatever the system scroll direction: natural scrolling
    /// (`inverted`) reports the content's motion, which matches the fingers. The "natural
    /// movement" option flips only skip swipes, so content follows the fingers there too.
    nonisolated static func direction(dx: CGFloat, dy: CGFloat, inverted: Bool, naturalSkip: Bool) -> SwipeDirection {
        let toFingers: CGFloat = inverted ? 1 : -1
        let x = dx * toFingers * (naturalSkip ? -1 : 1), y = dy * toFingers
        return abs(x) > abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .down : .up)
    }

    static func selfCheck() {
        // Natural scrolling on (the macOS default): fingers down → positive deltaY.
        precondition(direction(dx: 0, dy: 50, inverted: true, naturalSkip: false) == .down, "natural: fingers down")
        precondition(direction(dx: 0, dy: -50, inverted: false, naturalSkip: false) == .down, "classic: fingers down")
        precondition(direction(dx: 50, dy: 5, inverted: true, naturalSkip: false) == .right, "natural: fingers right")
        precondition(direction(dx: -50, dy: 5, inverted: false, naturalSkip: false) == .right, "classic: fingers right")
        precondition(direction(dx: 50, dy: 5, inverted: true, naturalSkip: true) == .left, "natural movement flips skips")
        precondition(direction(dx: 5, dy: 50, inverted: true, naturalSkip: true) == .down, "…but not vertical swipes")
    }

    /// Two-finger swipes: accumulate a gesture, fire once per gesture past a threshold.
    private func handleScroll(_ e: NSEvent) {
        if e.phase == .began || (e.phase.isEmpty && e.momentumPhase.isEmpty && !scrollLocked) {
            if e.phase == .began { scrollAccumulator = .zero; scrollLocked = false }
        }
        guard e.momentumPhase.isEmpty, !scrollLocked else {
            if e.phase == .ended || e.phase == .cancelled { scrollLocked = false }
            return
        }
        scrollAccumulator.width += e.scrollingDeltaX
        scrollAccumulator.height += e.scrollingDeltaY
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 40 : 3
        let dx = scrollAccumulator.width, dy = scrollAccumulator.height
        guard max(abs(dx), abs(dy)) > threshold else { return }
        scrollLocked = true
        scrollAccumulator = .zero
        Island.shared.swipe(Self.direction(dx: dx, dy: dy, inverted: e.isDirectionInvertedFromDevice, naturalSkip: Preferences.shared.naturalSwipe))
        if e.phase.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.scrollLocked = false } }
    }
}
