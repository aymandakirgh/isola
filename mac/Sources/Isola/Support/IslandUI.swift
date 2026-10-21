import SwiftUI

/// Shared look for island content (mirrors the web demo's palette).
enum Palette {
    /// Primary text/icons on the black island (orange-25).
    static let ink = Color(red: 1, green: 0.98, blue: 0.957)
    /// Secondary text (stone-300 at 85%).
    static let muted = Color(red: 0.84, green: 0.83, blue: 0.82).opacity(0.85)
    static let faint = Color(red: 0.34, green: 0.33, blue: 0.31)
    static let green = Color(red: 0.53, green: 0.94, blue: 0.67)  // green-300
    static let red = Color(red: 1, green: 0.39, blue: 0.4)
    static let amber = Color(red: 1, green: 0.8, blue: 0.3)
}

/// Circular level ring, as in the earbuds-connected notification.
struct BatteryRing: View {
    var level: Double
    var color: Color? = nil
    var size: CGFloat = 20
    var lineWidth: CGFloat = 2.5

    var body: some View {
        let tint = color ?? (level <= 0.2 ? Palette.red : Palette.green)
        ZStack {
            Circle().stroke(tint.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, level)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size - lineWidth, height: size - lineWidth)
        .animation(.easeInOut(duration: 0.4), value: level)
    }
}

/// Horizontal level bar for HUDs and progress.
struct LevelBar: View {
    var value: Double
    var tint: Color = Palette.ink
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.22))
                Capsule().fill(tint).frame(width: max(height, geo.size.width * max(0, min(1, value))))
            }
        }
        .frame(height: height)
        .animation(.interpolatingSpring(mass: 1, stiffness: 300, damping: 30), value: value)
    }
}

/// Endless marquee (two copies leap-frogging) with soft edge fades, 30 pt/s like the web demo.
struct Marquee<Content: View>: View {
    var speed: CGFloat = 30
    @ViewBuilder var content: Content
    @StateObject private var model = MarqueeModel()

    var body: some View {
        GeometryReader { geo in
            let w = model.width
            let scrolls = w > geo.size.width
            TimelineView(.animation(paused: !scrolls)) { timeline in
                let t = timeline.date.timeIntervalSince(model.start)
                let offset = scrolls ? -CGFloat(t * speed).truncatingRemainder(dividingBy: w) : 0
                HStack(spacing: 0) {
                    content.fixedSize().background(GeometryReader { g in Color.clear.onAppear { model.width = g.size.width } })
                    if scrolls { content.fixedSize() }
                }
                .offset(x: offset)
                .frame(width: geo.size.width, alignment: scrolls ? .leading : .center)
            }
            .mask(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.07), .init(color: .black, location: 0.11), .init(color: .black, location: 0.89), .init(color: .clear, location: 0.93)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
    }
}

final class MarqueeModel: ObservableObject {
    @Published var width: CGFloat = 0
    let start = Date()
}

extension View {
    /// Standard SF Symbol sizing inside island wings.
    func islandSymbol(_ size: CGFloat = 16) -> some View {
        font(.system(size: size, weight: .semibold)).symbolRenderingMode(.hierarchical)
    }
}
