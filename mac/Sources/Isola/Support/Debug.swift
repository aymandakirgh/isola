import AppKit

/// Command channel for scripting and tests: `isolactl <command> key=value ...`
/// posts a distributed notification that lands here. Any process on the Mac can post one (and
/// read the replies), so a release build listens only when asked to:
/// `defaults write app.isola.mac debug.channel -bool true`, or ISOLA_DEBUG=1 at launch.
@MainActor
enum Debug {
    static let notification = Notification.Name("app.isola.debug")
    private static var handlers: [String: ([String: String]) -> Void] = [:]

    static var enabled: Bool {
        #if DEBUG
            return true
        #else
            return UserDefaults.standard.bool(forKey: "debug.channel") || ProcessInfo.processInfo.environment["ISOLA_DEBUG"] == "1"
        #endif
    }

    static func on(_ command: String, _ handler: @escaping ([String: String]) -> Void) {
        handlers[command] = handler
    }

    /// Runs a command in this process, whether or not the channel listens (the menu's timers).
    static func run(_ command: String, _ args: [String: String] = [:]) {
        handlers[command]?(args)
    }

    static func start() {
        guard enabled else { return }
        registerBuiltins()
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            let args = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated {
                guard let handler = handlers[command] else { return NSLog("isola: unknown debug command %@", command) }
                handler(args)
            }
        }
    }

    private static func registerBuiltins() {
        let island = Island.shared
        on("hover") { island.setHovering($0["on"] != "0") }
        on("press") { island.setPressed($0["on"] != "0") }
        on("tap") { island.tap(option: $0["option"] == "1") }
        on("expand") { island.setExpanded($0["on"] != "0") }
        on("peek") { island.quickPeek($0["on"] != "0", for: $0["for"].flatMap(Double.init)) }
        on("cycle") { _ in island.cycle() }
        on("swipe") { args in
            let dir: SwipeDirection = switch args["dir"] {
            case "left": .left
            case "right": .right
            case "up": .up
            default: .down
            }
            island.swipe(dir)
        }
        on("dismiss") { _ in island.dismissTransient() }
        on("end") { if let id = $0["id"] { island.end(id) } }
        on("pref") { args in for (k, v) in args { Preferences.shared.set(k, v) } }
        on("quit") { _ in NSApp.terminate(nil) }
        on("state") { _ in
            reply("current=\(island.current?.id ?? "none") activities=\(island.activities.map(\.id)) expanded=\(island.expanded) peeking=\(island.peeking)")
        }
    }

    /// Answer a `state` / `*.state` command; isolactl prints it.
    static func reply(_ text: String) {
        DistributedNotificationCenter.default().postNotificationName(.init("app.isola.debug.reply"), object: text, userInfo: nil, deliverImmediately: true)
    }
}
