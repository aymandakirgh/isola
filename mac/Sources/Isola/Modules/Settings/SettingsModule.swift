import AppKit
import SwiftUI

/// Menu bar item, Settings window, onboarding and licensing.
@MainActor
enum SettingsModule {
    static func start() {
        License.shared.start()
        Updates.shared.start()
        StatusItem.shared.install()
        Debug.on("settings.open") { SettingsWindow.show(section: $0["section"]) }
        Debug.on("settings.close") { _ in SettingsWindow.close() }
        Debug.on("settings.onboarding") { _ in OnboardingWindow.show() }
        // The menu bar menu as it would open now ("⌥ " marks an Option alternate), and running one of its items by title.
        Debug.on("menu.state") { _ in Debug.reply(MenuEntry.describe(MenuEntry.entries(nowPlaying: nil))) }
        Debug.on("menu.run") { a in MenuEntry.run(a["title"] ?? "", in: MenuEntry.entries(nowPlaying: nil)) }
        // The shown island item's right-click menu: its titles, or opened under the island.
        Debug.on("island.menu.state") { _ in Debug.reply(Island.shared.current?.contextMenu.map { MenuEntry.describe($0()) } ?? "no menu") }
        Debug.on("island.menu") { _ in
            guard let rect = IslandWindows.shared.panels.first?.islandRect(slop: 0) else { return }
            IslandWindows.shared.showContextMenu(at: NSPoint(x: rect.midX, y: rect.minY))
        }
        // Live permission checks: `perm.request kind=bluetooth|calendar|focus|accessibility|automation|browser|fullDiskAccess|location`.
        Debug.on("perm.request") { a in
            if a["kind"] == "location" { return Weather.shared.useCurrentLocation() }
            Permission(rawValue: a["kind"] ?? "")?.request {}
        }
        Debug.on("perm.state") { _ in
            let states = Permission.allCases.map { "\($0.rawValue)=\($0.status())" } + ["location=\(Weather.shared.locationAuthorized)"]
            Debug.reply(states.joined(separator: " "))
        }
        Debug.on("license.set") { License.shared.activate($0["key"] ?? "") }
        Debug.on("license.reset") { _ in License.shared.reset() }
        Debug.on("license.state") { _ in
            let l = License.shared
            Debug.reply("key=\(License.mask(l.key)) server=\(l.serverStatus) registered=\(l.registered) devices=\(l.devices.count) pending=\(l.pendingDeactivations)")
        }
        Debug.on("update.check") { _ in Updates.shared.check() }
        // Update Now… and Restart Isola… for the release the last check found.
        Debug.on("update.install") { _ in if let r = Updates.shared.available { Updates.shared.install(r) } }
        Debug.on("update.restart") { _ in if let r = Updates.shared.available { Updates.shared.restart(r) } }
        Debug.on("update.prompt") { a in
            var release = Updates.sample
            release.version = a["version"] ?? release.version
            Island.shared.post(Updates.prompt(release), duration: 8)
        }
        if !UserDefaults.standard.bool(forKey: "onboarded") { OnboardingWindow.show() }
        // Last, so every module's settings exist when another Mac's values are applied.
        SettingsSync.shared.start()
    }

    static func gallery() {
        License.selfCheck()
        SettingsSync.selfCheck()
        selfCheck()
        Updates.gallery()
        SettingsGallery.render()
    }

    /// The menu bar menu's alternates, the sidebar's sections, onboarding's steps and the feedback e-mail.
    static func selfCheck() {
        for licensed in [false, true] {
            let entries = MenuEntry.entries(nowPlaying: nil, licensed: licensed)
            for (i, entry) in entries.enumerated() {
                guard case let .action(_, _, key, _, true, _) = entry else { continue }
                guard i > 0, case let .action(_, _, primaryKey, _, false, _) = entries[i - 1], primaryKey == key else {
                    preconditionFailure("menu: an Option alternate follows a plain item with the same key")
                }
            }
            precondition(MenuEntry.describe(entries).contains("Activate Isola…") != licensed, "menu: Activate only while unlicensed")
            precondition(MenuEntry.describe(entries).contains("Check License Status"), "menu: the license check is always there")
        }

        let page = { (id: String, group: String?) in SettingsPage(id: id, title: id, symbol: "circle", tint: .gray, group: group) { AnyView(EmptyView()) } }
        let pages = [page("general", nil), page("island", nil), page("battery", "notifications"), page("media", "liveActivities"),
                     page("focus", "notifications"), page("hud", nil), page("calendar", "liveActivities"), page("about", nil)]
        let sections = SettingsPages.sections(pages)
        precondition(sections.map(\.title) == [nil, "Notifications", "Live Activities", nil], "sidebar: groups under their titles")
        precondition(sections.map { $0.pages.map(\.id) } == [["general", "island"], ["battery", "focus"], ["media", "calendar"], ["hud", "about"]],
                     "sidebar: each page once, in order, ungrouped ones around the groups")

        let unlicensed = OnboardingModel(skipsLicense: false), licensed = OnboardingModel(skipsLicense: true)
        unlicensed.step = .permissions
        unlicensed.advance()
        licensed.step = .permissions
        licensed.advance()
        precondition(unlicensed.step == .license && licensed.step == .done, "onboarding: the license step only while unlicensed")
        licensed.back()
        precondition(licensed.step == .permissions && licensed.steps.count == 3, "onboarding: back skips it too")

        let issue = Feedback.issue(version: "1.4.7", build: "151", system: "Version 15.6 (Build 24G84)")
        let body = issue.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "body" }?.value
        precondition(issue?.absoluteString.hasPrefix("https://github.com/aymandakirgh/isola/issues/new?body=") == true, "feedback: a new GitHub issue")
        precondition(body?.hasSuffix("Isola 1.4.7 (151) · macOS Version 15.6 (Build 24G84)") == true, "feedback: version, build and macOS in the body")
    }
}

// MARK: - Menu bar item

/// Menu content as data, so the real NSMenu and the gallery mock can't drift apart. An
/// `alternate` action replaces the action before it while Option is held (same key, plus ⌥).
enum MenuEntry {
    case nowPlaying(title: String, artist: String)
    case action(String, symbol: String? = nil, key: String = "", checked: Bool = false, alternate: Bool = false, run: () -> Void)
    case submenu(String, symbol: String?, [MenuEntry])
    case separator

    /// `licensed` pins the license state (gallery); nil reads it.
    @MainActor static func entries(nowPlaying np: (title: String, artist: String, playing: Bool, shuffle: Bool, repeatMode: Int)?, licensed: Bool? = nil) -> [MenuEntry] {
        let licensed = licensed ?? (License.shared.status == .licensed)
        var list: [MenuEntry] = []
        if let np {
            let commands = NowPlayingState.shared.commands
            let repeatTitle = np.repeatMode == 1 ? "Repeat One" : np.repeatMode == 2 ? "Repeat All" : "Repeat"
            list += [
                .nowPlaying(title: np.title, artist: np.artist),
                .action(np.playing ? "Pause" : "Play", symbol: np.playing ? "pause.fill" : "play.fill") { commands.togglePlay() },
                .action("Next Track", symbol: "forward.fill") { commands.next() },
                .action("Previous Track", symbol: "backward.fill") { commands.previous() },
                .action("Shuffle", symbol: "shuffle", checked: np.shuffle) { commands.toggleShuffle() },
                .action(repeatTitle, symbol: np.repeatMode == 1 ? "repeat.1" : "repeat", checked: np.repeatMode != 0) { commands.cycleRepeat() },
                .separator,
            ]
        }
        let timers: [MenuEntry] = [1, 5, 10, 15, 25, 30, 60].map { minutes in
            .action("\(minutes) minute\(minutes == 1 ? "" : "s")") { startTimer(minutes: minutes) }
        }
        list += [
            .submenu("Start Timer", symbol: "timer", timers),
            .separator,
        ]
        // Showing the License page syncs with the licence server: that is the status check too.
        let license = { SettingsWindow.show(section: "license") }
        list += licensed ? [.action("Check License Status", symbol: "checkmark.seal", run: license)] : [
            .action("Activate Isola…", symbol: "key", run: license),
            .action("Check License Status", symbol: "checkmark.seal", alternate: true, run: license),
        ]
        list += [
            .action("Send Feedback to Isola…", symbol: "envelope") { Feedback.send() },
            .action("Copy Device ID", symbol: "doc.on.doc", alternate: true) { copyDeviceID() },
            .action("About Isola", symbol: "info.circle") { SettingsWindow.show(section: "about") },
            .action("Reset Onboarding", symbol: "arrow.counterclockwise", alternate: true) { resetOnboarding() },
            .action("Settings…", symbol: "gearshape", key: ",") { SettingsWindow.show() },
            .action("Reset Permissions…", symbol: "lock.rotation", key: ",", alternate: true) { resetPermissions() },
            .separator,
            .action("Quit Isola", key: "q") { NSApp.terminate(nil) },
        ]
        return list
    }

    /// Timers belong to the Calendar module; go through its `timer.start` command, in this process
    /// (release builds don't listen to isolactl).
    @MainActor static func startTimer(minutes: Int) {
        Debug.run("timer.start", ["seconds": String(minutes * 60)])
    }

    // MARK: Support tools (Option held)

    /// The id the licence server knows this Mac by, for support to look up. The hardware UUID
    /// itself never leaves the Mac: the license keeps only a salted hash of it.
    @MainActor static func copyDeviceID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(License.shared.thisMac.id, forType: .string)
    }

    @MainActor static func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: "onboarded")
        OnboardingWindow.show()
    }

    /// After a confirmation: macOS forgets every permission Isola has, and Isola relaunches.
    @MainActor static func resetPermissions() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reset Isola’s permissions?"
        alert.informativeText = "macOS forgets the Accessibility, Calendar, Bluetooth, Automation and other access you gave Isola, and Isola relaunches. Allow each one again when a feature asks for it."
        alert.addButton(withTitle: "Reset and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "All", Bundle.main.bundleIdentifier ?? "app.isola.mac"]
        if (try? reset.run()) != nil { reset.waitUntilExit() }
        relaunch()
    }

    /// Quits and opens the app again a second later. ponytail: only a bundled build reopens;
    /// `swift run` just quits.
    @MainActor static func relaunch() {
        let app = Bundle.main.bundlePath
        if app.hasSuffix(".app") {
            let reopen = Process()
            reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
            reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app]
            try? reopen.run()
        }
        NSApp.terminate(nil)
    }

    // MARK: isolactl

    /// One line per entry: "⌥ " before an alternate, "›" after a submenu.
    static func describe(_ entries: [MenuEntry]) -> String {
        entries.compactMap { entry in
            switch entry {
            case let .nowPlaying(title, _): title
            case let .action(title, _, _, _, alternate, _): (alternate ? "⌥ " : "") + title
            case let .submenu(title, _, _): title + " ›"
            case .separator: nil
            }
        }
        .joined(separator: " | ")
    }

    /// Runs the action titled `title` (a trailing "…" may be left out), alternates and submenus included.
    @MainActor static func run(_ title: String, in entries: [MenuEntry]) {
        let wanted = title.replacingOccurrences(of: "…", with: "")
        for entry in entries {
            switch entry {
            case let .action(t, _, _, _, _, action) where t.replacingOccurrences(of: "…", with: "") == wanted: return action()
            case let .submenu(_, _, children): run(title, in: children)
            default: continue
            }
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, key: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    static let shared = StatusItem()
    private var item: NSStatusItem?

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.glyph()
        item.button?.toolTip = "Isola"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        syncVisibility()
    }

    /// General › Hide menu bar icon.
    func syncVisibility() {
        item?.isVisible = !Preferences.shared.hideMenuBarIcon
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let np = NowPlayingState.shared
            menu.removeAllItems()
            let entries = MenuEntry.entries(nowPlaying: np.hasTrack ? (np.title, np.artist, np.isPlaying, np.shuffle, np.repeatMode) : nil)
            for entry in entries { menu.addItem(Self.item(for: entry)) }
        }
    }

    /// One entry as a real menu item (also the island's right-click menus).
    static func item(for entry: MenuEntry) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case let .nowPlaying(title, artist):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = symbol("music.note")
            item.subtitle = artist
            item.isEnabled = false
            return item
        case let .action(title, symbol, key, checked, alternate, run):
            let item = ClosureMenuItem(title, key: key, run: run)
            item.image = symbol.flatMap(Self.symbol)
            item.state = checked ? .on : .off
            if alternate {
                // Shown in place of the item before it (same key equivalent) while Option is down.
                item.isAlternate = true
                item.keyEquivalentModifierMask = key.isEmpty ? .option : [.command, .option]
            }
            return item
        case let .submenu(title, symbol, children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = symbol.flatMap(Self.symbol)
            let sub = NSMenu(title: title)
            for child in children { sub.addItem(Self.item(for: child)) }
            item.submenu = sub
            return item
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Template glyph: rounded-square ring with the island pill near the top.
    static func glyph(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 18
            NSColor.black.set()
            let ring = NSBezierPath(roundedRect: NSRect(x: 1.8 * s, y: 1.8 * s, width: 14.4 * s, height: 14.4 * s), xRadius: 4.6 * s, yRadius: 4.6 * s)
            ring.lineWidth = 1.7 * s
            ring.stroke()
            NSBezierPath(roundedRect: NSRect(x: 5.8 * s, y: 4.7 * s, width: 6.4 * s, height: 2.4 * s), xRadius: 1.2 * s, yRadius: 1.2 * s).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Gallery

/// Settings UI is AppKit-backed (Form, Toggle, Slider, List), which `ImageRenderer`
/// draws blank; these snapshots go through an offscreen window instead.
@MainActor
enum SettingsGallery {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--gallery") else { return nil }
        return URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "gallery")
    }

    static func snapshot<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) {
        guard let dir = directory else { return }
        let host = NSHostingView(rootView: view().frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        write(host, name: name, dir: dir)
    }

    /// The real Settings window (title bar included) for one section.
    static func window(_ name: String, section: String) {
        guard let dir = directory else { return }
        let nav = SettingsNav()
        nav.selection = section
        capture(SettingsWindow.makeWindow(nav: nav), name: name, dir: dir)
    }

    static func capture(_ w: NSWindow, name: String, dir: URL) {
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        guard let content = w.contentView else { return }
        write(content.superview ?? content, name: name, dir: dir)
    }

    private static func write(_ view: NSView, name: String, dir: URL) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return print("gallery: no bitmap for \(name) (\(type(of: view)) \(view.bounds))")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Window captures can run before Gallery.render makes the folder.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    static func render() {
        let license = License.shared
        let pages = SettingsPages.all(nav: SettingsNav()).filter { !$0.soon }.map(\.id).filter { $0 != "license" }
        for id in pages { window("settings-\(id)", section: id) }
        // The whole sidebar: groups, and File Tray with its Soon badge.
        if let dir = directory {
            let nav = SettingsNav()
            let w = SettingsWindow.makeWindow(nav: nav)
            w.setContentSize(NSSize(width: 680, height: 640))
            capture(w, name: "settings-sidebar", dir: dir)
        }

        let hour: TimeInterval = 3600
        license.preview(key: nil, devices: [], firstLaunch: Date().addingTimeInterval(-10 * hour))
        window("settings-license-trial", section: "license")
        license.preview(key: nil, devices: [], firstLaunch: Date().addingTimeInterval(-80 * hour), message: "That doesn’t look like an Isola license key.")
        window("settings-license-expired", section: "license")
        // In activation order, other Macs under the server's handles: Studio came first and is in use,
        // so this Mac can't remove it; the mini came first too but hasn't been seen for 30 days, and
        // the Air came after.
        let studio = LicensedMac(id: "kQ3vX9_bR2mT7wYc1LpZ0a", name: "Studio", model: "Mac14,13", activated: Date().addingTimeInterval(-40 * 24 * hour),
                                 lastSeen: Date().addingTimeInterval(-5 * hour))
        let mini = LicensedMac(id: "Hd4sT9pQ1wE6rY2uI8oP5a", name: "Mac mini", model: "Macmini9,1", activated: Date().addingTimeInterval(-200 * 24 * hour),
                               lastSeen: Date().addingTimeInterval(-62 * 24 * hour))
        var me = license.thisMac
        me.activated = Date().addingTimeInterval(-3 * 24 * hour)
        let air = LicensedMac(id: "Zp8LqW2nV5xR0tYb7MkC3d", name: "Air", model: "MacBookAir10,1", activated: Date().addingTimeInterval(-1 * 24 * hour))
        license.preview(key: License.makeKey(seed: 7), devices: [studio, mini, me], firstLaunch: Date().addingTimeInterval(-300 * hour))
        Updates.shared.preview(Updates.sample, checked: Date().addingTimeInterval(-2 * hour))
        window("settings-license-licensed", section: "license")
        license.preview(key: License.makeKey(seed: 7), devices: [studio, me, air], firstLaunch: Date().addingTimeInterval(-300 * hour),
                        message: License.unreachable, serverStatus: "offline")
        window("settings-license-offline", section: "license")

        // Onboarding on a first run: trial running, one permission prompt up (Browsers: "Waiting…").
        license.preview(key: nil, devices: [], firstLaunch: Date().addingTimeInterval(-hour))
        func onboarding(_ name: String, _ step: OnboardingModel.Step, _ setUp: (OnboardingModel) -> Void = { _ in }) {
            let model = OnboardingModel(skipsLicense: false)
            model.step = step
            model.statuses = [.accessibility: .granted, .calendar: .notDetermined, .bluetooth: .granted, .automation: .denied, .browser: .notDetermined,
                              .focus: .notDetermined, .fullDiskAccess: .denied]
            model.pending = [.browser]
            setUp(model)
            if let dir = directory { capture(OnboardingWindow.makeWindow(model: model), name: name, dir: dir) }
        }
        for step in OnboardingModel.Step.allCases { onboarding("onboarding-\(step)", step) }
        license.preview(key: nil, devices: [], firstLaunch: Date().addingTimeInterval(-hour), message: "That doesn’t look like an Isola license key.")
        onboarding("onboarding-license-key", .license) { $0.showKey = true }
        license.preview(key: License.makeKey(seed: 7), devices: [studio, me], firstLaunch: Date().addingTimeInterval(-hour))
        onboarding("onboarding-license-active", .license)

        snapshot("statusmenu", size: CGSize(width: 300, height: 360)) {
            StatusMenuMock(entries: MenuEntry.entries(nowPlaying: ("Ocean City", "Pacific Coliseum", true, true, 2), licensed: false))
        }
        snapshot("statusmenu-idle", size: CGSize(width: 300, height: 250)) {
            StatusMenuMock(entries: MenuEntry.entries(nowPlaying: nil, licensed: false))
        }
        // Option held: the support tools take the place of the items above them.
        snapshot("statusmenu-option", size: CGSize(width: 300, height: 250)) {
            StatusMenuMock(entries: MenuEntry.entries(nowPlaying: nil, licensed: false), option: true)
        }
        snapshot("statusmenu-licensed", size: CGSize(width: 300, height: 230)) {
            StatusMenuMock(entries: MenuEntry.entries(nowPlaying: nil, licensed: true))
        }
        snapshot("statusitem-glyph", size: CGSize(width: 120, height: 44)) {
            HStack(spacing: 18) {
                Image(nsImage: StatusItem.glyph()).renderingMode(.template).foregroundStyle(.primary)
                Image(nsImage: StatusItem.glyph(size: 36)).renderingMode(.template).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.bar)
        }
    }
}

/// Picture of the status menu for the gallery, drawn from the same entries.
struct StatusMenuMock: View {
    var entries: [MenuEntry]
    /// Option held: each alternate replaces the item before it.
    var option = false

    private var shown: [MenuEntry] {
        entries.reduce(into: []) { list, entry in
            guard case .action(_, _, _, _, true, _) = entry else { return list.append(entry) }
            if option { list[list.count - 1] = entry }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in row(entry) }
        }
        .padding(5)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 10)
    }

    @ViewBuilder private func row(_ entry: MenuEntry) -> some View {
        switch entry {
        case .separator:
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
        case let .nowPlaying(title, artist):
            line(symbol: "music.note", title: title, subtitle: artist, trailing: nil, dim: true)
        case let .action(title, symbol, key, checked, alternate, _):
            line(symbol: symbol, title: title, subtitle: nil, trailing: checked ? "✓" : key.isEmpty ? nil : "\(alternate ? "⌥⌘" : "⌘")\(key.uppercased())", dim: false)
        case let .submenu(title, symbol, _):
            line(symbol: symbol, title: title, subtitle: nil, trailing: "›", dim: false)
        }
    }

    private func line(symbol: String?, title: String, subtitle: String?, trailing: String?, dim: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol ?? "circle").opacity(symbol == nil ? 0 : 1).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let trailing { Text(trailing).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(dim ? .secondary : .primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
    }
}
