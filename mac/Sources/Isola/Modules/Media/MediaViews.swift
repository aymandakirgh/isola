import AVKit
import SwiftUI

// MARK: - Shared bits

struct ArtworkImage: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

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
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
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
        ArtworkImage(image: state.artwork, size: 22, radius: 6)
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

/// Four bars painted with the artwork gradient; flat when paused.
struct Spectrogram: View {
    let state: NowPlayingState
    private static let periods: [Double] = [0.95, 1.46, 0.82, 1.24]

    var body: some View {
        let gradient = LinearGradient(colors: state.colors.map { Color(nsColor: $0) }, startPoint: .top, endPoint: .bottom)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !state.isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let levels = AudioLevels.shared
            let live = MediaPreferences.shared.liveWaveform && levels.live
            HStack(spacing: 1.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = (t / Self.periods[i]).truncatingRemainder(dividingBy: 1)
                    let level = live ? Double(levels.bands[i]) : (1 - cos(phase * 2 * .pi)) / 2
                    let height = state.isPlaying ? 3 + 9 * level : 2
                    RoundedRectangle(cornerRadius: 1).fill(gradient).frame(width: 2, height: height)
                }
            }
        }
        .frame(width: 20, height: 20)
        .brightness(0.06)
        .animation(.easeInOut(duration: 0.5), value: state.isPlaying)
    }
}

struct MediaTrailing: View {
    let state: NowPlayingState

    var body: some View {
        if MediaPreferences.shared.spectrogram {
            Spectrogram(state: state)
        } else {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.ink.opacity(0.85))
                .frame(width: 20, height: 20)
        }
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

private struct ProgressScrubber: View {
    let state: NowPlayingState
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
                HStack(spacing: 10) {
                    Text(Self.format(elapsed)).frame(width: 34, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.ink.opacity(0.2))
                            Capsule().fill(Palette.ink.opacity(scrub.fraction == nil ? 0.88 : 1))
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
                    Text("-" + Self.format(duration - elapsed)).frame(width: 38, alignment: .trailing)
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

final class CopyFlash: ObservableObject {
    @Published var copied = false
}

private struct CopyLinkButton: View {
    let link: URL
    @StateObject private var flash = CopyFlash()

    var body: some View {
        ControlIcon(symbol: flash.copied ? "checkmark" : "link", size: 12, width: 24) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            flash.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { flash.copied = false }
        }
    }
}

struct ExpandedPlayer: View {
    let state: NowPlayingState
    let ui: MediaUI

    var body: some View {
        let prefs = MediaPreferences.shared
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ArtworkImage(image: state.artwork, size: 58, radius: 12)
                    .grayscale(prefs.grayscaleArtwork ? 1 : 0)
                    .opacity(!state.isPlaying && prefs.dimOnPause ? 0.7 : 1)
                    .scaleEffect(state.isPlaying ? 1 : 0.94)
                    .animation(.easeInOut(duration: 0.4), value: state.isPlaying)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayTitle(state)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                        if state.isExplicit { ExplicitBadge() }
                    }
                    if !state.artist.isEmpty {
                        Text(state.artist).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    if let link = ui.link { CopyLinkButton(link: link) }
                    if SpeedMenu.available { SpeedMenu(state: state, ui: ui) }
                    if ui.offscreen {
                        Image(systemName: "airplay.audio").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.72))
                    } else {
                        RoutePicker().frame(width: 20, height: 20)
                    }
                    SourceAppButton(state: state)
                }
            }
            ProgressScrubber(state: state).padding(.top, 14)
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
    }
}

// MARK: - Settings

struct MediaSettingsView: View {
    @Bindable var prefs = MediaPreferences.shared

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
                Toggle(isOn: $prefs.liveWaveform) {
                    Text("Live waveform")
                    Text("Bars follow the audio that's playing, at about 1% CPU. macOS asks for System Audio Recording access the first time.")
                }
                .disabled(!prefs.spectrogram)
                Toggle("Dim artwork when paused", isOn: $prefs.dimOnPause)
                Toggle("Grayscale artwork", isOn: $prefs.grayscaleArtwork)
                Toggle("Hide note symbol", isOn: $prefs.hideNoteSymbol)
                Toggle(isOn: $prefs.hideTitleExtras) {
                    Text("Hide title extras")
                    Text("Removes “feat.”, remaster notes and bracketed tags.")
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
                Text("Music and Spotify are read with AppleScript when macOS withholds system now-playing info; the first use asks for Automation access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

