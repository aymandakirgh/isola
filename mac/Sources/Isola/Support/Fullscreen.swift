import AppKit

/// Hides the island on a display while a fullscreen app or game covers it (the other
/// displays keep theirs), and on every display while Mission Control is up.
@MainActor
enum Fullscreen {
    static func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { evaluate() } }
        }
        // Mission Control has no notification; a light poll catches it.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in MainActor.assumeIsolated { evaluate() } }
        Debug.on("fullscreen.state") { _ in
            evaluate()
            let screens = NSScreen.screens.map { "\($0.displayID)=\($0.localizedName)" }
            Debug.reply("hidden=\(Island.shared.suppressed.sorted()) screens=\(screens)")
        }
    }

    static func evaluate() {
        let p = Preferences.shared
        // Nothing to hide for: skip the window list.
        let hidden = p.hideInFullscreen || p.hideWhileGaming || p.hideInMissionControl ? coveredDisplays(p) : []
        if Island.shared.suppressed != hidden { Island.shared.suppressed = hidden }
    }

    private static func coveredDisplays(_ p: Preferences) -> Set<CGDirectDisplayID> {
        // CG window bounds use a top-left origin on the main display.
        let main = NSScreen.screens.first?.frame.height ?? 0
        let displays = NSScreen.screens.map { s in
            Display(id: s.displayID, frame: CGRect(x: s.frame.minX, y: main - s.frame.maxY, width: s.frame.width, height: s.frame.height), notch: s.safeAreaInsets.top)
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var hidden = Set<CGDirectDisplayID>()
        for w in windows {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = display(filledBy: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0), in: displays)
            else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if (w[kCGWindowOwnerName as String] as? String) == "Dock", layer > 0 {
                if p.hideInMissionControl { return Set(displays.map(\.id)) }
            } else if layer == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
                if p.hideInFullscreen || (p.hideWhileGaming && isGame(w[kCGWindowOwnerPID as String] as? pid_t)) { hidden.insert(id) }
            }
        }
        return hidden
    }

    /// A screen in window-list coordinates, with the height of its camera housing (0 if none).
    struct Display {
        var id: CGDirectDisplayID
        var frame: CGRect
        var notch: CGFloat
    }

    /// The display a window fills: its whole frame or, on a notched display (where fullscreen
    /// windows sit below the camera housing), the frame minus the notch strip.
    nonisolated static func display(filledBy window: CGRect, in displays: [Display]) -> CGDirectDisplayID? {
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }
        return displays.first { d in
            let belowNotch = CGRect(x: d.frame.minX, y: d.frame.minY + d.notch, width: d.frame.width, height: d.frame.height - d.notch)
            return same(window, d.frame) || (d.notch > 0 && same(window, belowNotch))
        }?.id
    }

    private static func isGame(_ pid: pid_t?) -> Bool {
        guard let pid, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return false }
        return (info["LSApplicationCategoryType"] as? String)?.contains("games") == true
    }

    static func selfCheck() {
        let builtIn = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: 32)
        let external = Display(id: 2, frame: CGRect(x: 1512, y: -458, width: 2560, height: 1440), notch: 0)
        let both = [builtIn, external]
        precondition(display(filledBy: CGRect(x: 0, y: 0, width: 1512, height: 982), in: both) == 1, "fullscreen: whole frame")
        precondition(display(filledBy: CGRect(x: 0, y: 32, width: 1512, height: 950), in: both) == 1, "fullscreen below the notch")
        precondition(display(filledBy: CGRect(x: 1512, y: -458, width: 2560, height: 1440), in: both) == 2, "fullscreen on the second display")
        precondition(display(filledBy: CGRect(x: 1512, y: -433, width: 2560, height: 1415), in: both) == nil, "no notch strip on a plain display")
        precondition(display(filledBy: CGRect(x: 0, y: 37, width: 1512, height: 900), in: both) == nil, "an ordinary window")
    }
}
