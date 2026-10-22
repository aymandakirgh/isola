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
        // Live permission checks: `perm.request kind=bluetooth|calendar|focus|accessibility|automation|fullDiskAccess|location`.
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
        Updates.gallery()
        SettingsGallery.render()
    }
}

// MARK: - Menu bar item

/// Menu content as data, so the real NSMenu and the gallery mock can't drift apart.
enum MenuEntry {
    case nowPlaying(title: String, artist: String)
    case action(String, symbol: String? = nil, key: String = "", checked: Bool = false, run: () -> Void)
    case submenu(String, symbol: String?, [MenuEntry])
    case separator

    @MainActor static func entries(nowPlaying np: (title: String, artist: String, playing: Bool, shuffle: Bool, repeatMode: Int)?) -> [MenuEntry] {
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
            .action("Settings…", symbol: "gearshape", key: ",") { SettingsWindow.show() },
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
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let np = NowPlayingState.shared
            menu.removeAllItems()
            let entries = MenuEntry.entries(nowPlaying: np.hasTrack ? (np.title, np.artist, np.isPlaying, np.shuffle, np.repeatMode) : nil)
            for entry in entries { menu.addItem(Self.item(for: entry)) }
        }
    }

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
        case let .action(title, symbol, key, checked, run):
            let item = ClosureMenuItem(title, key: key, run: run)
            item.image = symbol.flatMap(Self.symbol)
            item.state = checked ? .on : .off
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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    static func render() {
        let license = License.shared
        let pages = SettingsPages.all(nav: SettingsNav()).map(\.id).filter { $0 != "license" }
        for id in pages { window("settings-\(id)", section: id) }

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

        for step in OnboardingModel.Step.allCases {
            let model = OnboardingModel()
            model.step = step
            model.statuses = [.accessibility: .granted, .calendar: .notDetermined, .bluetooth: .granted, .automation: .denied, .focus: .notDetermined, .fullDiskAccess: .denied]
            if let dir = directory { capture(OnboardingWindow.makeWindow(model: model), name: "onboarding-\(step)", dir: dir) }
        }

        snapshot("statusmenu", size: CGSize(width: 300, height: 300)) {
            StatusMenuMock(entries: MenuEntry.entries(nowPlaying: ("Ocean City", "Pacific Coliseum", true, true, 2)))
        }
        snapshot("statusmenu-idle", size: CGSize(width: 300, height: 190)) {
            StatusMenuMock(entries: MenuEntry.entries(nowPlaying: nil))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in row(entry) }
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
        case let .action(title, symbol, key, checked, _):
            line(symbol: symbol, title: title, subtitle: nil, trailing: checked ? "✓" : key.isEmpty ? nil : "⌘\(key.uppercased())", dim: false)
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
