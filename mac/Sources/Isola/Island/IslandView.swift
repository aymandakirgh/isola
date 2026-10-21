import SwiftUI

/// Rounded rect with independent top/bottom continuous corners (animatable).
struct IslandShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous
        ).path(in: rect)
    }
}

/// Fill shape: the island plus, for notch styles, small concave "ears" that blend
/// it into the top edge like a hardware notch.
struct IslandFill: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var ears: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = IslandShape(top: top, bottom: bottom).path(in: rect)
        guard ears > 0 else { return p }
        p.move(to: CGPoint(x: rect.minX - ears, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + ears), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        p.move(to: CGPoint(x: rect.maxX + ears, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + ears), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Wing enter/leave, mirroring the web demo: fade + blur + horizontal squash.
private struct WingEffect: ViewModifier {
    var opacity: Double
    var blur: CGFloat
    var scaleX: CGFloat
    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).scaleEffect(x: scaleX, y: 1)
    }
}

@MainActor
extension AnyTransition {
    static var islandWing: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: WingEffect(opacity: 0, blur: 10, scaleX: 0.001), identity: WingEffect(opacity: 1, blur: 0, scaleX: 1))
                .animation(.easeInOut(duration: 0.3)),
            removal: .modifier(active: WingEffect(opacity: 0, blur: 8, scaleX: 0.25), identity: WingEffect(opacity: 1, blur: 0, scaleX: 1))
                .animation(.easeInOut(duration: 0.25))
        )
    }

    static var islandPeek: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: WingEffect(opacity: 0, blur: 10, scaleX: 0.75), identity: WingEffect(opacity: 1, blur: 0, scaleX: 1))
                .animation(Springs.peekIn.delay(0.05)),
            removal: .modifier(active: WingEffect(opacity: 0, blur: 10, scaleX: 0.75), identity: WingEffect(opacity: 1, blur: 0, scaleX: 1))
                .animation(Springs.peekOut)
        )
    }
}

/// Snapshot of what to draw; shared by the live window and the offscreen gallery.
struct IslandState {
    var item: IslandItem?
    /// Duo mode's second activity, drawn in a bubble beside the island.
    var secondary: IslandItem?
    var expanded = false
    var peeking = false
    var hovering = false
    var pressed = false
}

/// The island's black body and its content for one state.
struct IslandBody: View {
    let state: IslandState
    let size: CGSize
    let radii: (top: CGFloat, bottom: CGFloat)
    let geometry: NotchGeometry

    var body: some View {
        let g = geometry
        ZStack(alignment: .top) {
            IslandFill(top: radii.top, bottom: radii.bottom, ears: g.attached ? g.height * 0.2 : 0)
                .fill(Color.black)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(IslandShape(top: radii.top, bottom: radii.bottom))
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topTrailing) {
            if let second = state.secondary, !state.expanded {
                DuoBubble(item: second, geometry: g)
                    .offset(x: g.bubbleGap + g.bubble, y: g.bubbleInset)
                    .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color(red: 1, green: 0.98, blue: 0.957))
    }

    @ViewBuilder private var content: some View {
        let g = geometry
        if state.expanded, let item = state.item, let expanded = item.expanded {
            expanded
                .id("expanded-\(item.id)")
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)).animation(.easeOut(duration: 0.25)))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        if let item = state.item {
                            item.leading.id("lead-\(item.id)").transition(.islandWing)
                        }
                    }
                    .frame(width: g.side + 8, height: g.height, alignment: .leading)
                    Spacer(minLength: 0)
                    ZStack(alignment: .trailing) {
                        if let item = state.item {
                            item.trailing.id("trail-\(item.id)").transition(.islandWing)
                        }
                    }
                    .frame(width: g.side + 8, height: g.height, alignment: .trailing)
                }
                .frame(height: g.height)
                if let item = state.item, let peek = item.peek, state.peeking || item.alwaysPeek {
                    peek
                        .id("peek-\(item.id)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.islandPeek)
                }
            }
        }
    }
}

/// Duo mode: the other live activity's leading glyph in a small black circle.
struct DuoBubble: View {
    let item: IslandItem
    let geometry: NotchGeometry

    var body: some View {
        let d = geometry.bubble
        ZStack {
            Circle().fill(Color.black)
            // Wings carry about 10 pt of leading padding: pull the glyph back to the centre.
            item.leading
                .offset(x: -5)
                .id("bubble-\(item.id)")
                .transition(.islandWing)
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
    }
}

/// Live island for one screen, driven by `Island.shared`.
struct IslandView: View {
    let geometry: NotchGeometry
    var island = Island.shared

    var body: some View {
        let g = geometry
        let visible = island.visible(in: g)
        let lift = island.hovering && !island.peeking && !island.expanded
        IslandBody(state: island.state, size: island.size(in: g), radii: island.radii(in: g), geometry: g)
            .scaleEffect(island.pressed ? 0.94 : lift ? 1.075 : 1, anchor: .top)
            .shadow(color: .black.opacity(lift ? 0.25 : 0), radius: 8, y: 2)
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.6, anchor: .top)
            .animation(Springs.expand, value: visible)
            .padding(.top, g.topMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
