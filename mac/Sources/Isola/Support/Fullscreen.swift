import AppKit

/// Hides the island while a fullscreen app, a game, or Mission Control is in front.
@MainActor
enum Fullscreen {
    static func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { evaluate() } }
        }
        // Mission Control has no notification; a light poll catches it.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in MainActor.assumeIsolated { evaluate() } }
    }

    static func evaluate() {
        let p = Preferences.shared
        let front = NSWorkspace.shared.frontmostApplication
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let screens = NSScreen.screens.map { s -> CGRect in
            // CG window bounds use a top-left origin.
            let main = NSScreen.screens.first?.frame.height ?? s.frame.height
            return CGRect(x: s.frame.minX, y: main - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        func covers(_ w: [String: Any]) -> Bool {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return screens.contains { $0.equalTo(r) }
        }
        let frontFullscreen = windows.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == front?.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0 && covers($0)
        }
        let missionControl = windows.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "Dock" && (($0[kCGWindowLayer as String] as? Int) ?? 0) > 0 && covers($0)
        }
        var hide = false
        if frontFullscreen, p.hideInFullscreen { hide = true }
        if frontFullscreen, p.hideWhileGaming, isGame(front) { hide = true }
        if missionControl, p.hideInMissionControl { hide = true }
        if Island.shared.suppressed != hide { Island.shared.suppressed = hide }
    }

    private static func isGame(_ app: NSRunningApplication?) -> Bool {
        guard let url = app?.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return false }
        return (info["LSApplicationCategoryType"] as? String)?.contains("games") == true
    }
}
