import AppKit

/// Command channel for scripting and tests: `isolactl <command> key=value ...`
/// posts a distributed notification that lands here.
@MainActor
enum Debug {
    static let notification = Notification.Name("app.isola.debug")
    private static var handlers: [String: ([String: String]) -> Void] = [:]

    static func on(_ command: String, _ handler: @escaping ([String: String]) -> Void) {
        handlers[command] = handler
    }

    static func start() {
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
        on("tap") { _ in island.tap() }
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
            let s = "current=\(island.current?.id ?? "none") activities=\(island.activities.map(\.id)) expanded=\(island.expanded) peeking=\(island.peeking)"
            DistributedNotificationCenter.default().postNotificationName(.init("app.isola.debug.reply"), object: s, userInfo: nil, deliverImmediately: true)
        }
    }
}
