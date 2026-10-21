import AppKit
import SwiftUI

extension NotchGeometry {
    /// Floating pill on a notchless display (36pt, like this repo's demo machine).
    static let pillPreview = NotchGeometry(hasNotch: false, notchWidth: 100.8, height: 36, attached: false)
    /// 14"/16" MacBook Pro hardware notch.
    static let notchPreview = NotchGeometry(hasNotch: true, notchWidth: 185, height: 32, attached: true)
}

/// Offscreen snapshots of island states and module views: `Isola --gallery <dir>`
/// writes one PNG per entry, so states can be checked without driving the live UI.
@MainActor
enum Gallery {
    private struct Entry {
        let name: String
        let size: CGSize
        let view: AnyView
    }

    private static var entries: [Entry] = []

    static func add<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) {
        entries.append(Entry(name: name, size: size, view: AnyView(view())))
    }

    /// The island in a given state over a wallpaper-like strip, as it sits under the menu bar.
    static func island(
        _ name: String, item: IslandItem?, expanded: Bool = false, peeking: Bool = false,
        hovering: Bool = false, geometry g: NotchGeometry = .pillPreview
    ) {
        let state = IslandState(item: item, expanded: expanded, peeking: peeking, hovering: hovering)
        let size = Island.size(for: state, in: g)
        let radii = Island.radii(for: state, in: g)
        let canvas = CGSize(width: max(size.width + 120, 420), height: size.height + g.topMargin + 40)
        add(name, size: canvas) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.62), Color(red: 0.42, green: 0.24, blue: 0.7)], startPoint: .top, endPoint: .bottom)
                IslandBody(state: state, size: size, radii: radii, geometry: g)
                    .scaleEffect(hovering ? 1.075 : 1, anchor: .top)
                    .padding(.top, g.topMargin)
            }
        }
    }

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries {
            let url = dir.appendingPathComponent("\(entry.name).png")
            let rep = entry.name.hasSuffix("settings") ? hostedSnapshot(entry) : rendererSnapshot(entry)
            try? rep?.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("rendered \(entries.count) gallery entries to \(dir.path)")
    }

    /// 2x snapshot through SwiftUI's offscreen renderer (fine for island content).
    private static func rendererSnapshot(_ entry: Entry) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: entry.view.frame(width: entry.size.width, height: entry.size.height))
        renderer.scale = 2
        return renderer.cgImage.map(NSBitmapImageRep.init(cgImage:))
    }

    /// AppKit-backed controls (Form, Toggle, Picker, TextField) only draw inside a real
    /// hosting view, so settings pages go through an offscreen window instead.
    private static func hostedSnapshot(_ entry: Entry) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: entry.view.frame(width: entry.size.width, height: entry.size.height))
        host.frame = NSRect(origin: .zero, size: entry.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
