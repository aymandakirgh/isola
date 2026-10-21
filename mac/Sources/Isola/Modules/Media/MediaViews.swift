import AVKit
import CoreAudio
import SwiftUI

// MARK: - Shared bits

struct ArtworkImage: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    /// Where the specular highlight sits (unit square); nil draws none.
    var glare: UnitPoint?
    /// The glare at rest: light from the top left.
    static let light = UnitPoint(x: 0.25, y: 0.12)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Palette.muted)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if let glare {
                RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0)], center: .center, startRadius: 0, endRadius: size * 0.7)
                    .frame(width: size * 1.4, height: size * 1.4)
                    .position(x: glare.x * size, y: glare.y * size)
                    .blendMode(.plusLighter)
                    .animation(.easeOut(duration: 0.3), value: glare)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Reports the pointer over its view in unit coordinates, nil once it leaves. An `.activeAlways`
/// tracking area, so it keeps working while Isola isn't the active app.
private struct PointerTracker: NSViewRepresentable {
    let onMove: (UnitPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onMove = onMove }

    final class TrackingView: NSView {
        var onMove: ((UnitPoint?) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onMove?(UnitPoint(x: p.x / bounds.width, y: 1 - p.y / bounds.height))
        }

        override func mouseExited(with event: NSEvent) { onMove?(nil) }
    }
}

private struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.interpolatingSpring(mass: 1, stiffness: 300, damping: 20), value: configuration.isPressed)
    }
}

private struct ControlIcon: View {
    let symbol: String
    var on = true
    var size: CGFloat = 16
    var width: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(on ? Palette.ink : Palette.ink.opacity(0.38))
                .frame(width: width, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }
}

@MainActor
private func displayTitle(_ state: NowPlayingState) -> String {
    MediaPreferences.shared.hideTitleExtras ? TitleCleaner.clean(state.title) : state.title
}

// MARK: - Compact wings

/// Left wing: the artwork. Dims and shrinks when paused; card-flips on track change.
struct WingArtwork: View {
    let state: NowPlayingState
    let ui: MediaUI

    var body: some View {
        let prefs = MediaPreferences.shared
        let island = Island.shared
        ArtworkImage(image: state.artwork, size: 22, radius: 6, glare: prefs.artworkGlare ? ArtworkImage.light : nil)
            .grayscale(prefs.grayscaleArtwork ? 1 : 0)
            .opacity(!state.isPlaying && prefs.dimOnPause ? 0.6 : 1)
            .scaleEffect(state.isPlaying ? 1 : 0.85)
            .animation(.easeInOut(duration: 0.5), value: state.isPlaying)
            // Two mirrored flips cancel out: the art squeezes to nothing and back, like a card turning.
            .scaleEffect(x: ui.flipped ? -1 : 1)
            .scaleEffect(x: ui.flipped ? -1 : 1)
            .animation(.easeInOut(duration: 0.5), value: ui.flipped)
            // While quick-peeking the artwork grows a little, as in the web demo.
            .scaleEffect(island.peeking && island.current?.id == "media" ? 1.2 : 1, anchor: UnitPoint(x: 0.2, y: 0))
            .animation(.easeInOut(duration: 0.3), value: island.peeking)
    }
}

enum SpectrogramStyle: String, CaseIterable, Identifiable {
    case bars, mirrored, dots, wave
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Spectrogram geometry for four band levels (bass → treble, 0...1); all zero is the paused look.
struct SpectrogramShape: Shape {
    var style: SpectrogramStyle
    var levels: [Double]

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(levels[0], levels[1]), AnimatablePair(levels[2], levels[3])) }
        set { levels = [newValue.first.first, newValue.first.second, newValue.second.first, newValue.second.second] }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        // Island springs can overshoot an interpolated level past 0...1.
        let levels = levels.map { min(1, max(0, $0)) }
        switch style {
        case .bars, .mirrored:
            // Mirrored: seven thinner bars, bass in the middle.
            let bands = style == .bars ? [0, 1, 2, 3] : [3, 2, 1, 0, 1, 2, 3]
            let (w, gap, tallest): (CGFloat, CGFloat, CGFloat) = style == .bars ? (2, 1.5, 12) : (1.5, 1.25, 14)
            let x0 = r.midX - (CGFloat(bands.count) * (w + gap) - gap) / 2
            for (i, band) in bands.enumerated() {
                let h = 2 + (tallest - 2) * levels[band]
                p.addRoundedRect(in: CGRect(x: x0 + CGFloat(i) * (w + gap), y: r.midY - h / 2, width: w, height: h), cornerSize: CGSize(width: w / 2, height: w / 2))
            }
        case .dots:
            // A tiny LED meter: one to four dots per band, lit from the bottom.
            let d: CGFloat = 2.5, step: CGFloat = 4, side = 4 * step - (step - d)
            for (i, level) in levels.enumerated() {
                for row in 0...Int((level * 3).rounded()) {
                    p.addEllipse(in: CGRect(x: r.midX - side / 2 + CGFloat(i) * step, y: r.midY + side / 2 - d - CGFloat(row) * step, width: d, height: d))
                }
            }
        case .wave:
            // A smooth line swinging up and down through the bands.
            let points = [CGPoint(x: r.minX + 1, y: r.midY)]
                + levels.enumerated().map { i, level in CGPoint(x: r.minX + 1 + CGFloat(i + 1) * 3.6, y: r.midY + (i.isMultiple(of: 2) ? -11 : 11) * level) }
                + [CGPoint(x: r.maxX - 1, y: r.midY)]
            p.move(to: points[0])
            for i in 1..<points.count - 1 {
                let next = points[i + 1]
                p.addQuadCurve(to: CGPoint(x: (points[i].x + next.x) / 2, y: (points[i].y + next.y) / 2), control: points[i])
            }
            p.addLine(to: points[points.count - 1])
            return p.strokedPath(StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        return p
    }
}

/// Band levels in the chosen style, painted with the artwork gradient; flat when paused.
/// `bands` are live levels from the audio tap; nil animates canned ones.
struct Spectrogram: View {
    let state: NowPlayingState
    var style = SpectrogramStyle.bars
    var bands: [Float]?
    private static let periods: [Double] = [0.95, 1.46, 0.82, 1.24]

    var body: some View {
        let gradient = LinearGradient(colors: state.colors.map { Color(nsColor: $0) }, startPoint: .top, endPoint: .bottom)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !state.isPlaying || bands != nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let canned = Self.periods.map { (1 - cos((t / $0).truncatingRemainder(dividingBy: 1) * 2 * .pi)) / 2 }
            SpectrogramShape(style: style, levels: !state.isPlaying ? [0, 0, 0, 0] : bands.map { $0.map(Double.init) } ?? canned)
                .fill(gradient)
        }
        .frame(width: 20, height: 20)
        .brightness(0.06)
        .animation(.easeInOut(duration: 0.5), value: state.isPlaying)
    }
}

/// The Focus symbol in its colour, standing in for the spectrogram.
struct FocusWingSymbol: View {
    let focus: FocusState

    var body: some View {
        Image(systemName: DeviceSymbol.resolve(focus.symbol, fallback: "moon.fill"))
            .islandSymbol(14)
            .foregroundStyle(Color(nsColor: focus.tint))
    }
}

struct MediaTrailing: View {
    let state: NowPlayingState
    var focus = FocusState.shared

    var body: some View {
        let prefs = MediaPreferences.shared
        let showsFocus = prefs.showsFocus(focus)
        ZStack {
            if showsFocus {
                FocusWingSymbol(focus: focus).transition(.blurReplace)
            } else if prefs.spectrogram {
                let levels = AudioLevels.shared
                Spectrogram(state: state, style: prefs.spectrogramStyle, bands: prefs.liveWaveform && levels.live ? levels.bands : nil)
                    .transition(.blurReplace)
            } else {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .transition(.blurReplace)
            }
        }
        .frame(width: 20, height: 20)
        .animation(.easeInOut(duration: 0.45), value: showsFocus)
    }
}

/// Quick peek: "♪ Title ∙ Artist" scrolling under the notch.
struct MediaPeek: View {
    let state: NowPlayingState

    var body: some View {
        let prefs = MediaPreferences.shared
        let live = state.duration <= 0
        Marquee {
            HStack(spacing: 3) {
                if !prefs.hideNoteSymbol {
                    Image(systemName: live || state.isPodcast ? "mic.fill" : "music.note").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color(white: 0.45))
                }
                if state.inTransition { SourceTag(text: "AutoMix") }
                let title = displayTitle(state)
                if !title.isEmpty { Text(title) }
                if !title.isEmpty, !state.artist.isEmpty { Text("∙").foregroundStyle(Color(white: 0.45)) }
                if !state.artist.isEmpty { Text(state.artist) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 6)
        }
        .frame(height: 16)
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }
}

// MARK: - Expanded player

final class ScrubModel: ObservableObject {
    @Published var fraction: Double?
}

struct ProgressScrubber: View {
    let state: NowPlayingState
    /// Fill with the artwork colours instead of ink.
    var gradient = false
    /// Total duration after the bar instead of the time left.
    var totalTime = false
    @StateObject private var scrub = ScrubModel()

    static func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "-:--" }
        let s = Int(t)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var body: some View {
        if state.duration <= 0 {
            HStack(spacing: 6) {
                Circle().fill(Palette.red).frame(width: 6, height: 6)
                Text("Live").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, minHeight: 14)
        } else {
            // Only on screen while expanded, so a per-frame clock costs little and moves smoothly.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !state.isPlaying)) { context in
                let duration = state.duration
                let elapsed = scrub.fraction.map { $0 * duration } ?? state.currentElapsed(at: context.date)
                let fraction = min(1, max(0, elapsed / duration))
                // Darker artwork colour at the start, brighter at the playhead.
                let fill = gradient
                    ? AnyShapeStyle(LinearGradient(colors: state.colors.reversed().map { Color(nsColor: $0) }, startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Palette.ink.opacity(scrub.fraction == nil ? 0.88 : 1))
                HStack(spacing: 10) {
                    Text(Self.format(elapsed)).frame(width: 34, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.ink.opacity(0.2))
                            Capsule().fill(fill)
                                .frame(width: max(6, geo.size.width * fraction))
                        }
                        .frame(height: scrub.fraction == nil ? 5 : 7)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { scrub.fraction = min(1, max(0, $0.location.x / geo.size.width)) }
                                .onEnded { _ in
                                    if let f = scrub.fraction { state.seek(to: f * duration) }
                                    scrub.fraction = nil
                                }
                        )
                        .animation(.easeOut(duration: 0.15), value: scrub.fraction == nil)
                    }
                    .frame(height: 14)
                    Text(totalTime ? Self.format(duration) : "-" + Self.format(duration - elapsed))
                        .frame(width: 38, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture { MediaPreferences.shared.showTotalTime.toggle() }
                }
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8.5, weight: .black))
            .foregroundStyle(Color.black)
            .frame(width: 12, height: 12)
            .background(RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Palette.ink.opacity(0.55)))
    }
}

@MainActor
private enum AppIcons {
    static var cache: [String: NSImage] = [:]
    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = sdr(NSWorkspace.shared.icon(forFile: url.path), points: 24)
        cache[bundleID] = icon
        return icon
    }

    /// Recent app icons carry extended-range layers that flip offscreen renders into EDR
    /// (everything else turns grey); a plain 8-bit sRGB copy keeps them ordinary.
    private static func sdr(_ icon: NSImage, points: CGFloat) -> NSImage {
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return icon }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private struct SourceAppButton: View {
    let state: NowPlayingState

    var body: some View {
        if let id = state.sourceBundleID, let icon = AppIcons.icon(id) {
            Button { state.commands.openSource() } label: {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 24, height: 24)
            }
            .buttonStyle(Pressable())
        }
    }
}

private struct SpeedMenu: View {
    let state: NowPlayingState
    let ui: MediaUI
    static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// Music and Spotify scripting has no rate control.
    static var available: Bool {
        if case .script = NowPlayingSources.shared.source { false } else { true }
    }

    static func label(_ rate: Double) -> String {
        (rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)) + "×"
    }

    var body: some View {
        let label = Text(Self.label(state.rate))
            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
            .foregroundStyle(Palette.ink.opacity(0.8))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(Palette.ink.opacity(0.12)))
        if ui.offscreen {
            label
        } else {
            Menu {
                ForEach(Self.rates, id: \.self) { rate in
                    Button(Self.label(rate)) { state.setRate(rate) }
                }
            } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }
}

/// System AirPlay / output picker.
private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(NSColor(white: 1, alpha: 0.72), for: .normal)
        view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// The expanded player's output glyph and name: the HUD's classification, with plain speakers drawn as speakers.
extension HUDOutput {
    var playerSymbol: String { symbol ?? (transport == kAudioDeviceTransportTypeBuiltIn ? "speaker.wave.2.fill" : "hifispeaker.fill") }
    var playerName: String { symbol == nil ? name : label }
}

/// The current output's glyph (slashed while muted); opens the volume row.
private struct OutputButton: View {
    let ui: MediaUI

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { ui.volumeOpen.toggle() }
        } label: {
            Image(systemName: ui.muted ? "speaker.slash.fill" : ui.output.playerSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(ui.volumeOpen ? 1 : 0.72))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.ink.opacity(ui.volumeOpen ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }
}

/// Output volume in place of the progress bar: mute toggle, level, device name and the AirPlay picker.
private struct VolumeRow: View {
    let ui: MediaUI

    var body: some View {
        let level = ui.volume ?? 0
        HStack(spacing: 10) {
            Button { ui.toggleMute() } label: {
                Image(systemName: ui.muted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 14, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            GeometryReader { geo in
                LevelBar(value: level, tint: Palette.ink.opacity(ui.muted ? 0.35 : 0.88), height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { ui.setVolume(Double($0.location.x / geo.size.width)) })
            }
            .frame(height: 14)
            .opacity(ui.volume == nil ? 0.4 : 1)
            .allowsHitTesting(ui.volume != nil)
            Text(ui.output.playerName).lineLimit(1)
            if ui.offscreen {
                Image(systemName: "airplay.audio").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.72))
            } else {
                RoutePicker().frame(width: 20, height: 20)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Palette.muted)
    }
}

final class CopyFlash: ObservableObject {
    /// Result of the last copy, shown briefly.
    @Published var copied: Bool?
}

private struct CopyLinkButton: View {
    let state: NowPlayingState
    @StateObject private var flash = CopyFlash()

    var body: some View {
        ControlIcon(symbol: flash.copied.map { $0 ? "checkmark" : "xmark" } ?? "link", size: 12, width: 24) {
            state.commands.copyLink { ok in
                flash.copied = ok
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { flash.copied = nil }
            }
        }
    }
}

/// The expanded artwork; its glare follows the pointer while hovering.
private struct PlayerArtwork: View {
    let state: NowPlayingState
    let ui: MediaUI

    var body: some View {
        let prefs = MediaPreferences.shared
        ArtworkImage(image: state.artwork, size: 58, radius: 12, glare: prefs.artworkGlare ? ui.glarePoint ?? ArtworkImage.light : nil)
            .grayscale(prefs.grayscaleArtwork ? 1 : 0)
            .opacity(!state.isPlaying && prefs.dimOnPause ? 0.7 : 1)
            .scaleEffect(state.isPlaying ? 1 : 0.94)
            .animation(.easeInOut(duration: 0.4), value: state.isPlaying)
            .overlay { if prefs.artworkGlare, !ui.offscreen { PointerTracker { ui.glarePoint = $0 } } }
            .onTapGesture { state.commands.openSource() }
    }
}

private struct LikeButton: View {
    let state: NowPlayingState

    var body: some View {
        ControlIcon(symbol: state.liked ? "heart.fill" : "heart", size: 12, width: 24) { state.commands.toggleLike() }
            .contentTransition(.symbolEffect(.replace))
    }
}

/// "Lossless", "Dolby Atmos" or "AutoMix", in small outlined capitals.
private struct SourceTag: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 4)
            .frame(height: 12)
            .overlay(Capsule().strokeBorder(Palette.muted.opacity(0.55), lineWidth: 0.75))
            .fixedSize()
    }
}

struct ExpandedPlayer: View {
    let state: NowPlayingState
    let ui: MediaUI

    var body: some View {
        let prefs = MediaPreferences.shared
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                PlayerArtwork(state: state, ui: ui)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayTitle(state)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                        if state.isExplicit { ExplicitBadge() }
                    }
                    HStack(spacing: 6) {
                        if !state.artist.isEmpty {
                            Text(state.artist).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        if let tag = state.inTransition ? "AutoMix" : state.audioFormat { SourceTag(text: tag) }
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    if state.canLike { LikeButton(state: state) }
                    if state.canCopyLink { CopyLinkButton(state: state) }
                    if SpeedMenu.available { SpeedMenu(state: state, ui: ui) }
                    OutputButton(ui: ui)
                    SourceAppButton(state: state)
                }
            }
            ZStack {
                if ui.volumeOpen {
                    VolumeRow(ui: ui).transition(.opacity)
                } else {
                    ProgressScrubber(state: state, gradient: prefs.gradientProgress, totalTime: prefs.showTotalTime).transition(.opacity)
                }
            }
            .padding(.top, 14)
            // Podcasts skip within the episode (15 s back, 30 s ahead) instead of changing track.
            let podcast = state.isPodcast && state.duration > 0
            HStack(spacing: 0) {
                ControlIcon(symbol: "shuffle", on: state.shuffle, size: 13) { state.commands.toggleShuffle() }
                Spacer()
                if podcast {
                    ControlIcon(symbol: "gobackward.15", size: 17) { state.seek(to: state.currentElapsed() - 15) }
                } else {
                    ControlIcon(symbol: "backward.fill", size: 17) { state.commands.previous() }
                }
                Spacer()
                ControlIcon(symbol: state.isPlaying ? "pause.fill" : "play.fill", size: 24, width: 44) { state.commands.togglePlay() }
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                if podcast {
                    ControlIcon(symbol: "goforward.30", size: 17) { state.seek(to: state.currentElapsed() + 30) }
                } else {
                    ControlIcon(symbol: "forward.fill", size: 17) { state.commands.next() }
                }
                Spacer()
                ControlIcon(symbol: state.repeatMode == 1 ? "repeat.1" : "repeat", on: state.repeatMode != 0, size: 13) { state.commands.cycleRepeat() }
            }
            .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 14, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Outputs come and go (AirPods, AirPlay): poll the default device while the player is open.
            guard !ui.offscreen else { return }
            while !Task.isCancelled {
                ui.refreshOutput()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear {
            // Collapsing under the pointer skips mouseExited, so the glare would reopen where it was.
            ui.glarePoint = nil
            if !MediaPreferences.shared.keepVolumeOpen { ui.volumeOpen = false }
        }
    }
}

// MARK: - Settings

struct MediaSettingsView: View {
    @Bindable var prefs = MediaPreferences.shared

    /// The built-in modes, plus the saved choice and whichever Focus is on (custom modes are
    /// only known once seen, and only with Full Disk Access).
    private var focusModes: [String] {
        let focus = FocusState.shared
        let names = FocusMonitor.known.values.map(\.name) + [prefs.focusMode] + (focus.active ? [focus.name] : [])
        return Set(names).filter { !$0.isEmpty }.sorted()
    }

    private var sourceDescription: String {
        switch NowPlayingSources.shared.source {
        case .mediaRemote: "System (MediaRemote)"
        case .bridge: "System (MediaRemote helper)"
        case .script(let player): player == .music ? "Music (AppleScript)" : "Spotify (AppleScript)"
        case .simulated: "Simulated"
        case .none: "Nothing playing"
        }
    }

    var body: some View {
        Form {
            Section("Island") {
                Toggle("Spectrogram", isOn: $prefs.spectrogram)
                Picker("Style", selection: $prefs.spectrogramStyle) {
                    ForEach(SpectrogramStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.spectrogram)
                Toggle(isOn: $prefs.liveWaveform) {
                    Text("Live waveform")
                    Text("Bars follow the audio that's playing, at about 1% CPU. macOS asks for System Audio Recording access the first time.")
                }
                .disabled(!prefs.spectrogram)
                Toggle(isOn: $prefs.focusReplace) {
                    Text("Replace spectrogram with Focus")
                    Text("While the chosen Focus is on, the wing shows its symbol in its colour.")
                }
                Picker("Focus", selection: $prefs.focusMode) {
                    Text("Any Focus").tag("")
                    ForEach(focusModes, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!prefs.focusReplace)
                Toggle("Dim artwork when paused", isOn: $prefs.dimOnPause)
                Toggle("Grayscale artwork", isOn: $prefs.grayscaleArtwork)
                Toggle(isOn: $prefs.artworkGlare) {
                    Text("Artwork glare")
                    Text("A soft highlight on the cover that follows the pointer in the player.")
                }
                Toggle("Hide note symbol", isOn: $prefs.hideNoteSymbol)
                Toggle(isOn: $prefs.hideTitleExtras) {
                    Text("Hide title extras")
                    Text("Removes “feat.”, remaster notes and bracketed tags.")
                }
            }
            Section("Player") {
                Toggle("Gradient progress bar", isOn: $prefs.gradientProgress)
                Toggle(isOn: $prefs.showTotalTime) {
                    Text("Show total duration")
                    Text("Instead of the time left. Clicking the time in the player switches it too.")
                }
                Toggle(isOn: $prefs.keepVolumeOpen) {
                    Text("Keep volume control open")
                    Text("The output button's volume slider stays out when the player closes and reopens.")
                }
            }
            Section("Activity") {
                Picker("Keep after pausing", selection: $prefs.idleSeconds) {
                    Text("Off").tag(0.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("Until playback stops").tag(-1.0)
                }
                Toggle("Ignore browsers", isOn: $prefs.excludeBrowsers)
                Toggle("Ignore calls and chat apps", isOn: $prefs.excludeInapt)
            }
            Section("Source") {
                LabeledContent("Now playing", value: sourceDescription)
                Text("Music and Spotify are read with AppleScript only when macOS withholds system now-playing info and Automation access is already granted. Liking in Music and copying a Spotify or browser link ask for it the first time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

