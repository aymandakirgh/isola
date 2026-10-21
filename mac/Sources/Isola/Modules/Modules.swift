import SwiftUI

/// Every feature module plugs in here.
@MainActor
enum Modules {
    static func start() {
        CoreDemo.start()
        MediaModule.start()
        SystemModule.start()
        HUDModule.start()
        CalendarModule.start()
        LockScreenModule.start()
        SettingsModule.start()
    }

    static func registerGallery() {
        CoreDemo.gallery()
        MediaModule.gallery()
        SystemModule.gallery()
        HUDModule.gallery()
        CalendarModule.gallery()
        LockScreenModule.gallery()
        SettingsModule.gallery()
    }
}

/// A sample item exercising the core (wings, peek, expanded) — `isolactl demo`.
@MainActor
enum CoreDemo {
    static func item(id: String = "demo") -> IslandItem {
        IslandItem(id: id, kind: .liveActivity) {
            Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).padding(.leading, 12)
        } trailing: {
            Text("Hi").font(.system(size: 13, weight: .semibold)).padding(.trailing, 12)
        }
        .peek { Text("Isola core demo · quick peek").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
        .expanded { Text("Expanded").font(.system(size: 20, weight: .bold)) }
    }

    static func start() {
        // `demo id=other` adds a second activity (duo mode); `key` is the content key a swipe-up
        // dismissal waits on; `inactive=1` marks it idle like paused media.
        Debug.on("demo") { args in
            let id = args["id"] ?? "demo"
            if args["off"] != nil { return Island.shared.end(id) }
            let inactive = args["inactive"] == "1"
            Island.shared.start(item(id: id).contentKey(args["key"]).inactive { inactive })
        }
        Debug.on("activity.dismiss") { args in
            if let id = args["id"] ?? Island.shared.currentActivity?.id { Island.shared.dismiss(id) }
        }
        Debug.on("island.state") { _ in
            let island = Island.shared
            Debug.reply(
                "current=\(island.current?.id ?? "none") rotation=\(island.sortedActivities.map(\.id)) "
                    + "dismissed=\(island.dismissed.keys.sorted()) hiddenOn=\(island.suppressed.sorted()) expanded=\(island.expanded)"
            )
        }
    }

    static func gallery() {
        IslandWindows.selfCheck()
        Island.selfCheck()
        Fullscreen.selfCheck()
        Gallery.island("core-idle-notch", item: nil, geometry: .notchPreview)
        Gallery.island("core-activity-pill", item: item())
        Gallery.island("core-activity-notch", item: item(), geometry: .notchPreview)
        Gallery.island("core-hover", item: item(), hovering: true)
        Gallery.island("core-peek", item: item(), peeking: true)
        Gallery.island("core-expanded", item: item(), expanded: true)

        // Whole General and Island pages (the settings window crops them).
        Gallery.add("core-general-settings", size: CGSize(width: 520, height: 1010)) {
            GeneralPage(nav: SettingsNav()).background(Color(nsColor: .windowBackgroundColor))
        }
        Gallery.add("core-island-settings", size: CGSize(width: 520, height: 640)) {
            IslandPage().background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
