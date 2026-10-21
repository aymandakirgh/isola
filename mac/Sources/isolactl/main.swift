import Foundation

// isolactl <command> [key=value ...] — drives a running Isola (see Debug.swift).
let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    print("usage: isolactl <command> [key=value ...]")
    exit(1)
}
var info: [String: String] = [:]
for arg in args.dropFirst() {
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    info[parts[0]] = parts.count > 1 ? parts[1] : "1"
}
// `state` and `*.state` commands reply; print the answer (or give up after a second).
let wantsReply = command == "state" || command.hasSuffix(".state")
if wantsReply {
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.isola.debug.reply"), object: nil, queue: .main) { note in
        print(note.object as? String ?? "")
        exit(0)
    }
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("app.isola.debug"), object: command, userInfo: info, deliverImmediately: true
)
if wantsReply {
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    print("no reply (is Isola running?)")
    exit(2)
}
