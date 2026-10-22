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

/// iOS-style marquee, 30 pt/s like the web demo: text that doesn't fit rests left-aligned for
/// `pause` seconds, scrolls until the next copy takes its place, and repeats. Near the edges it
/// blurs and fades progressively (only fades, with General › Progressive blur off; the leading
/// edge only while moving). Text that fits sits centred, untouched.
struct Marquee<Content: View>: View {
    var speed: CGFloat = 30
    var pause: TimeInterval = 1.5
    /// Pins the loop clock (gallery snapshots).
    var clock: TimeInterval?
    /// Pins General › Progressive blur (gallery snapshots); nil follows the setting.
    var blur: Bool?
    @ViewBuilder var content: Content
    @StateObject private var model = MarqueeModel()

    var body: some View {
        GeometryReader { geo in
            let w = model.width
            let scrolls = w > geo.size.width
            TimelineView(.animation(paused: !scrolls || clock != nil)) { timeline in
                let t = clock ?? timeline.date.timeIntervalSince(model.start)
                let x = scrolls ? MarqueeModel.offset(at: t, width: w, speed: speed, pause: pause) : 0
                // The leading edge eases in over the first 12 pt of travel and out over the last 12.
                let lead = scrolls ? min(1, -x / 12, (w + x) / 12) : 0, trail: CGFloat = scrolls ? 1 : 0
                HStack(spacing: 0) {
                    content.fixedSize().background(GeometryReader { g in
                        // Re-measured when the text changes (a new track), which restarts the loop.
                        Color.clear
                            .onAppear { model.width = g.size.width }
                            .onChange(of: g.size.width) { _, width in
                                model.width = width
                                model.start = Date()
                            }
                    })
                    if scrolls { content.fixedSize() }
                }
                .offset(x: x)
                .frame(width: geo.size.width, alignment: scrolls ? .leading : .center)
                .progressiveBlur(blur ?? Preferences.shared.progressiveBlur, radius: 2.5, sharp: MarqueeMask.sharp(lead, trail), blurred: MarqueeMask.blurred(lead, trail))
                .mask(MarqueeMask.fade(lead, trail))
            }
        }
    }
}

/// Edge masks along a marquee: sharp text hands over to a blurred copy near each edge, which
/// then fades out. `lead` and `trail` scale each side (0: no edge effect).
private enum MarqueeMask {
    static func sharp(_ lead: CGFloat, _ trail: CGFloat) -> LinearGradient {
        ramp([(0, 1 - lead), (0.04, 1 - lead), (0.16, 1), (0.84, 1), (0.96, 1 - trail), (1, 1 - trail)])
    }

    static func blurred(_ lead: CGFloat, _ trail: CGFloat) -> LinearGradient {
        ramp([(0, lead), (0.04, lead), (0.16, 0), (0.84, 0), (0.96, trail), (1, trail)])
    }

    static func fade(_ lead: CGFloat, _ trail: CGFloat) -> LinearGradient {
        ramp([(0, 1 - lead), (0.07, 1 - lead), (0.11, 1), (0.89, 1), (0.93, 1 - trail), (1, 1 - trail)])
    }

    private static func ramp(_ stops: [(location: CGFloat, opacity: CGFloat)]) -> LinearGradient {
        LinearGradient(stops: stops.map { .init(color: .black.opacity($0.opacity), location: $0.location) }, startPoint: .leading, endPoint: .trailing)
    }
}

final class MarqueeModel: ObservableObject {
    @Published var width: CGFloat = 0
    /// When the current loop began.
    var start = Date()

    /// Scroll offset `t` seconds into the loop: rest at 0 for `pause`, then travel one copy's width.
    static func offset(at t: TimeInterval, width: CGFloat, speed: CGFloat, pause: TimeInterval) -> CGFloat {
        guard width > 0, speed > 0 else { return 0 }
        let p = max(0, t).truncatingRemainder(dividingBy: pause + Double(width / speed))
        return p < pause ? 0 : -CGFloat(p - pause) * speed
    }

    static func selfCheck() {
        precondition(offset(at: 1, width: 300, speed: 30, pause: 1.5) == 0, "marquee rests at the start")
        precondition(offset(at: 2.5, width: 300, speed: 30, pause: 1.5) == -30, "then scrolls at 30 pt/s")
        precondition(offset(at: 11.5, width: 300, speed: 30, pause: 1.5) == 0, "one copy later it rests again")
        precondition(offset(at: 12.5, width: 300, speed: 30, pause: 1.5) == 0, "for the whole pause")
    }
}

extension View {
    /// Progressive blur with public SwiftUI only: the view under one gradient mask and a blurred
    /// copy under another, so content dissolves into an edge instead of being cut by it. The copy
    /// takes no clicks and is hidden from VoiceOver.
    func progressiveBlur<Sharp: View, Blurred: View>(radius: CGFloat, sharp: Sharp, blurred: Blurred) -> some View {
        mask(sharp).overlay(blur(radius: radius).mask(blurred).allowsHitTesting(false).accessibilityHidden(true))
    }

    /// The same, only when `on` (General › Progressive blur); off, the view is left as it is.
    @ViewBuilder func progressiveBlur<Sharp: View, Blurred: View>(_ on: Bool, radius: CGFloat, sharp: Sharp, blurred: Blurred) -> some View {
        if on { progressiveBlur(radius: radius, sharp: sharp, blurred: blurred) } else { self }
    }
}

extension View {
    /// Standard SF Symbol sizing inside island wings.
    func islandSymbol(_ size: CGFloat = 16) -> some View {
        font(.system(size: size, weight: .semibold)).symbolRenderingMode(.hierarchical)
    }
}
