import IOKit.pwr_mgt
import SwiftUI

/// Lock Screen widgets: now playing, focus, weather, battery, connectivity and calendar,
/// drawn over the macOS Lock Screen (and optionally the screen saver).
@MainActor
enum LockScreenModule {
    static func start() {
        registerSettings()
        NowPlayingActivity.shared.observe()
        let dnc = DistributedNotificationCenter.default()
        let events: [(String, (LockScreenController) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.setLocked(true) }),
            ("com.apple.screenIsUnlocked", { $0.setLocked(false) }),
            ("com.apple.screensaver.didstart", { $0.setScreensaver(true) }),
            ("com.apple.screensaver.didstop", { $0.setScreensaver(false) }),
        ]
        for (name, apply) in events {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { apply(LockScreenController.shared) }
            }
        }
        Debug.on("lock.preview") { LockScreenController.shared.preview($0["on"] != "0") }
        Debug.on("lock.pref") { args in for (k, v) in args { LockScreenPreferences.shared.set(k, v) } }
    }

    static func registerSettings() {
        SettingsRegistry.add("lockscreen", title: "Lock Screen", symbol: "lock.rectangle", order: 60) {
            LockScreenSettingsView()
        }
    }

    static func gallery() {
        registerSettings()
        LockScreenGallery.register()
    }
}

/// Shows/hides the per-screen widget windows on the lock-screen space.
@MainActor
final class LockScreenController {
    static let shared = LockScreenController()
    private var windows: [NSWindow] = []
    private var previewWindow: NSWindow?
    private var assertion: IOPMAssertionID = 0
    private var locked = false
    private var screensaver = false

    func setLocked(_ on: Bool) {
        locked = on
        refresh()
    }

    func setScreensaver(_ on: Bool) {
        screensaver = on
        refresh()
    }

    func refresh() {
        let p = LockScreenPreferences.shared
        if p.enabled, locked || (screensaver && p.showOnScreensaver) { present() } else { dismiss() }
        keepAwake(p.enabled && p.keepAwake && locked)
    }

    private func present() {
        guard windows.isEmpty, let space = LockScreenSpace.shared else { return }
        for screen in NSScreen.screens {
            let window = Self.window(frame: Self.bandFrame(on: screen), content: LiveLockScreen())
            space.adopt(window)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    private func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// The band between the system clock and the login controls (27%–74% from the top).
    static func bandFrame(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let width = min(f.width, 760)
        return NSRect(x: f.midX - width / 2, y: f.minY + f.height * 0.26, width: width, height: f.height * 0.47)
    }

    private static func window<V: View>(frame: NSRect, content: V) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        return window
    }

    /// `isolactl lock.preview`: the same layout over the desktop wallpaper in an ordinary
    /// window, with sample data where nothing live exists yet. Never uses the lock space.
    func preview(_ on: Bool) {
        guard on else {
            previewWindow?.close()
            previewWindow = nil
            return
        }
        guard previewWindow == nil, let screen = NSScreen.main else { return }
        let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:))
        let view = ScaledCanvas(canvas: screen.frame.size) {
            LockScreenComposition(wallpaper: wallpaper) { LiveLockScreen(preview: true) }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Lock Screen Preview"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        window.center()
        window.orderFrontRegardless()
        previewWindow = window
    }

    private func keepAwake(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Isola Lock Screen widgets" as CFString, &assertion
            )
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

@MainActor
private enum LockScreenGallery {
    /// The site wallpaper when rendering from `mac/`, else a gradient.
    static let wallpaper = NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/../public/images/wallpaper.jpg")

    static func register() {
        let s = LockScreenData.sample
        let screen = CGSize(width: 2560, height: 1440)
        let full: [(String, LockScreenOptions)] = [
            ("lockscreen-full", LockScreenOptions()),
            ("lockscreen-full-dark-detailed", LockScreenOptions(style: .dark, weatherStyle: .detailed, showVolume: true)),
            ("lockscreen-full-artwork", LockScreenOptions(style: .artwork, offset: -40)),
        ]
        for (name, options) in full {
            Gallery.add(name, size: CGSize(width: 1280, height: 720)) {
                ScaledCanvas(canvas: screen) {
                    LockScreenComposition(wallpaper: wallpaper, date: s.event!.start.addingTimeInterval(-25 * 60)) {
                        LockScreenBand(data: s, options: options, showsNowPlaying: true, volume: options.showVolume ? .constant(0.62) : nil, commands: MediaCommands())
                    }
                }
                .environment(\.lockGalleryRender, true)
            }
        }

        var paused = s
        paused.track?.isPlaying = false
        let cards: [(String, NowPlayingWidget)] = [
            ("lockscreen-nowplaying-glass", NowPlayingWidget(track: s.track)),
            ("lockscreen-nowplaying-dark", NowPlayingWidget(track: s.track, style: .dark)),
            ("lockscreen-nowplaying-artwork", NowPlayingWidget(track: s.track, style: .artwork)),
            ("lockscreen-nowplaying-clear", NowPlayingWidget(track: s.track, style: .clear)),
            ("lockscreen-nowplaying-grayscale", NowPlayingWidget(track: s.track, style: .artwork, grayscale: true)),
            ("lockscreen-nowplaying-paused", NowPlayingWidget(track: paused.track)),
            ("lockscreen-nowplaying-volume", NowPlayingWidget(track: s.track, volume: .constant(0.62))),
            ("lockscreen-nowplaying-muted", NowPlayingWidget(track: s.track, output: .preset("airpodspro"), volume: .constant(0.62, muted: true))),
            ("lockscreen-nowplaying-empty", NowPlayingWidget(track: nil)),
        ]
        for (name, card) in cards {
            Gallery.add(name, size: CGSize(width: 420, height: 280)) { backdrop { card } }
        }

        Gallery.add("lockscreen-info-compact", size: CGSize(width: 1040, height: 90)) {
            backdrop { LockInfoRow(data: s, options: LockScreenOptions()) }
        }
        Gallery.add("lockscreen-info-detailed", size: CGSize(width: 1240, height: 90)) {
            backdrop { LockInfoRow(data: s, options: LockScreenOptions(weatherStyle: .detailed)) }
        }
        Gallery.add("lockscreen-info-nocolor", size: CGSize(width: 1040, height: 90)) {
            backdrop { LockInfoRow(data: s, options: LockScreenOptions(calendarColors: false)) }
        }
        var charging = s
        charging.battery = LockBattery(level: 0.46, charging: true, timeToEmpty: nil)
        charging.devices = [ConnectedDevice(id: "low", name: "Studio Headphones", symbol: "headphones", battery: 0.14, caseBattery: nil)]
        Gallery.add("lockscreen-info-charging-lowdevice", size: CGSize(width: 1040, height: 90)) {
            backdrop { LockInfoRow(data: charging, options: LockScreenOptions()) }
        }
        // Forms are AppKit-backed and come out blank in ImageRenderer: snapshot a hosting view instead.
        let settingsSize = CGSize(width: 560, height: 800)
        if let settings = snapshot(LockScreenSettingsView(), size: settingsSize) {
            Gallery.add("lockscreen-settings", size: settingsSize) { Image(nsImage: settings) }
        }
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize) -> NSImage? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// A slice of wallpaper behind a widget, so glass reads as it does on screen.
    private static func backdrop<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.62), Color(red: 0.42, green: 0.24, blue: 0.7)], startPoint: .top, endPoint: .bottom)
            }
            content()
        }
        .clipped()
        .environment(\.lockGalleryRender, true)
        .environment(\.colorScheme, .dark)
    }
}
