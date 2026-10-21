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
    static func item() -> IslandItem {
        IslandItem(id: "demo", kind: .liveActivity) {
            Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).padding(.leading, 12)
        } trailing: {
            Text("Hi").font(.system(size: 13, weight: .semibold)).padding(.trailing, 12)
        }
        .peek { Text("Isola core demo · quick peek").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
        .expanded { Text("Expanded").font(.system(size: 20, weight: .bold)) }
    }

    static func start() {
        Debug.on("demo") { args in
            if args["off"] != nil { Island.shared.end("demo") } else { Island.shared.start(item()) }
        }
    }

    static func gallery() {
        IslandWindows.selfCheck()
        Gallery.island("core-idle-notch", item: nil, geometry: .notchPreview)
        Gallery.island("core-activity-pill", item: item())
        Gallery.island("core-activity-notch", item: item(), geometry: .notchPreview)
        Gallery.island("core-hover", item: item(), hovering: true)
        Gallery.island("core-peek", item: item(), peeking: true)
        Gallery.island("core-expanded", item: item(), expanded: true)
    }
}
