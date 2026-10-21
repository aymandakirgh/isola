import AppKit

@main
enum IsolaApp {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--gallery") {
            let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "gallery")
            MainActor.assumeIsolated {
                Modules.registerGallery()
                Gallery.render(to: dir)
            }
            exit(0)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Debug.start()
            IslandWindows.shared.start()
            Fullscreen.start()
            Modules.start()
        }
    }
}
