import CoreAudio
import Observation
import SwiftUI

// MARK: - Look

enum LockPalette {
    /// purple-300: the tinted text of the web demo's lock screen.
    static let purple = Color(red: 0.86, green: 0.70, blue: 1.0)
    static let stone900 = Color(red: 0.11, green: 0.10, blue: 0.09)
    static let stone950 = Color(red: 0.05, green: 0.04, blue: 0.035)
}

private struct GalleryRenderKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Offscreen renders can't sample what's behind a window, so glass falls back to a tint.
    var lockGalleryRender: Bool {
        get { self[GalleryRenderKey.self] }
        set { self[GalleryRenderKey.self] = newValue }
    }
}

// MARK: - Data

struct LockTrack {
    var title: String
    var artist: String
    var artwork: NSImage?
    var isPlaying: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
}

struct LockBattery {
    var level: Double
    var charging: Bool
    var timeToEmpty: Int?
}

struct LockWeather {
    var symbol: String
    var temperature: String
    var condition: String
    var precipitation: Double?
    /// "Rain at 18:00 · 60%" when rain is coming.
    var rain: String?
}

struct LockFocus {
    var name: String
    var symbol: String
}

/// Everything the widgets show, read from the shared stores (or sample data for previews).
struct LockScreenData {
    var track: LockTrack?
    var focus: LockFocus?
    var weather: LockWeather?
    var battery: LockBattery?
    var devices: [ConnectedDevice] = []
    var event: CalendarEvent?
    /// The default output device (the card's output glyph).
    var output = HUDOutput.preset("speakers")

    /// Call inside `body`: reading the @Observable stores makes SwiftUI track them.
    @MainActor static func live(at date: Date = Date()) -> LockScreenData {
        let np = NowPlayingState.shared, f = FocusState.shared, w = WeatherState.shared, p = PowerState.shared
        return LockScreenData(
            track: np.hasTrack
                ? LockTrack(title: np.title, artist: np.artist, artwork: np.artwork, isPlaying: np.isPlaying, elapsed: np.currentElapsed(at: date), duration: np.duration)
                : nil,
            focus: f.active ? LockFocus(name: f.name.isEmpty ? "Focus" : f.name, symbol: f.symbol) : nil,
            weather: w.available
                ? LockWeather(symbol: w.symbol, temperature: w.displayTemperature, condition: w.condition, precipitation: w.precipitationChance, rain: w.precipitationDetail)
                : nil,
            battery: p.hasBattery ? LockBattery(level: p.level, charging: p.charging, timeToEmpty: p.timeToEmpty) : nil,
            devices: DevicesState.shared.devices,
            event: CalendarState.shared.next,
            output: SystemAudio.output()  // polled with the band's 1 s refresh
        )
    }

    /// Previews fill whatever the shared stores don't have yet.
    func filled(with s: LockScreenData) -> LockScreenData {
        LockScreenData(
            track: track ?? s.track, focus: focus ?? s.focus, weather: weather ?? s.weather,
            battery: battery ?? s.battery, devices: devices.isEmpty ? s.devices : devices, event: event ?? s.event, output: output
        )
    }

    @MainActor static let sample = LockScreenData(
        track: LockTrack(title: "Ocean City", artist: "Pacific Coliseum", artwork: sampleArtwork, isPlaying: true, elapsed: 47, duration: 214),
        focus: LockFocus(name: "Work", symbol: "briefcase.fill"),
        weather: LockWeather(symbol: "sun.max.fill", temperature: "24°", condition: "Sunny", precipitation: 0.4, rain: "Showers at 18:00 · 40%"),
        battery: LockBattery(level: 0.82, charging: false, timeToEmpty: 214),
        devices: [ConnectedDevice(id: "sample", name: "Earbuds Pro", symbol: "airpodspro", battery: 0.76, caseBattery: 0.9)],
        event: CalendarEvent(
            id: "sample", title: "Design review", start: Date().addingTimeInterval(25 * 60), end: Date().addingTimeInterval(85 * 60),
            calendarColor: NSColor(red: 0.75, green: 0.52, blue: 0.99, alpha: 1), location: "Studio"
        )
    )

    /// Original placeholder art: a dusk horizon.
    @MainActor static let sampleArtwork: NSImage = NSImage(size: NSSize(width: 168, height: 168), flipped: false) { rect in
        NSGradient(colors: [NSColor(red: 0.29, green: 0.13, blue: 0.36, alpha: 1), NSColor(red: 0.89, green: 0.5, blue: 0.58, alpha: 1)])?
            .draw(in: rect, angle: 90)
        NSColor(red: 1, green: 0.84, blue: 0.62, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: 54, y: 52, width: 60, height: 60)).fill()
        NSColor(red: 0.2, green: 0.1, blue: 0.3, alpha: 0.85).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 168, height: 62)).fill()
        return true
    }
}

/// Snapshot of the Lock Screen preferences, so previews can show any style.
struct LockScreenOptions {
    var showNowPlaying = true
    var showFocus = true
    var showWeather = true
    var showBattery = true
    var showConnectivity = true
    var showCalendar = true
    var style: NowPlayingWidgetStyle = .glass
    var weatherStyle: WeatherWidgetStyle = .compact
    var offset: Double = 0
    var showVolume = false
    /// Calendar › "Use calendar colours".
    var calendarColors = true
    /// Media › "Grayscale artwork".
    var grayscaleArtwork = false

    @MainActor static var current: LockScreenOptions {
        let p = LockScreenPreferences.shared
        return LockScreenOptions(
            showNowPlaying: p.showNowPlaying, showFocus: p.showFocus, showWeather: p.showWeather, showBattery: p.showBattery,
            showConnectivity: p.showConnectivity, showCalendar: p.showCalendar, style: p.nowPlayingStyle,
            weatherStyle: p.weatherStyle, offset: p.nowPlayingOffset, showVolume: p.showVolumeControl,
            calendarColors: CalendarPreferences.shared.calendarColors, grayscaleArtwork: MediaPreferences.shared.grayscaleArtwork
        )
    }
}

/// Remembers when playback last started/stopped, for "hide while inactive".
@MainActor @Observable
final class NowPlayingActivity {
    static let shared = NowPlayingActivity()
    private(set) var changedAt = Date.distantPast
    private static let grace: TimeInterval = 10

    func observe() {
        withObservationTracking { _ = NowPlayingState.shared.isPlaying } onChange: {
            Task { @MainActor in
                NowPlayingActivity.shared.changedAt = Date()
                NowPlayingActivity.shared.observe()
            }
        }
    }

    func shows(_ track: LockTrack?, at date: Date) -> Bool {
        let p = LockScreenPreferences.shared
        guard p.showNowPlaying, let track else { return false }
        if track.isPlaying || !p.hideWhileInactive { return true }
        return !p.hideInstantly && date.timeIntervalSince(changedAt) < Self.grace
    }
}

/// The card's output volume row: live CoreAudio bindings, or fixed values in previews.
struct LockVolume {
    var level: Binding<Double>
    var muted: Binding<Bool>

    static func constant(_ level: Double, muted: Bool = false) -> LockVolume {
        LockVolume(level: .constant(level), muted: .constant(muted))
    }
}

// MARK: - Formatting

private func clock(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "-:--" }
    let s = Int(t.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

private func duration(minutes m: Int) -> String {
    m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

private func batterySymbol(_ b: LockBattery) -> String {
    if b.charging { return "battery.100percent.bolt" }
    switch b.level {
    case 0.88...: return "battery.100percent"
    case 0.62...: return "battery.75percent"
    case 0.37...: return "battery.50percent"
    case 0.12...: return "battery.25percent"
    default: return "battery.0percent"
    }
}

private func eventTime(_ e: CalendarEvent, now: Date) -> String {
    if e.start <= now { return "now" }
    let minutes = Int(e.start.timeIntervalSince(now) / 60)
    return minutes < 60 ? "in \(max(1, minutes))m" : e.start.formatted(date: .omitted, time: .shortened)
}

// MARK: - Now Playing widget

/// 328×174 glass card, as in the web demo's lock screen (with live controls).
struct NowPlayingWidget: View {
    var track: LockTrack?
    var style: NowPlayingWidgetStyle = .glass
    var grayscale = false
    /// The default output device, drawn at the end of the controls.
    var output = HUDOutput.preset("speakers")
    /// Shows the output volume row when set.
    var volume: LockVolume? = nil
    var commands: MediaCommands = MediaCommands()
    @Environment(\.lockGalleryRender) private var gallery

    var body: some View {
        let clear = style == .clear
        VStack(spacing: 0) {
            header
            progress.padding(.top, 16)
            controls.frame(maxHeight: .infinity, alignment: .bottom)
            if let volume { volumeRow(volume).padding(.top, 8) }
        }
        .padding(17)
        .frame(width: 328, height: volume == nil ? 174 : 204)
        // Clear has no card: artwork and text float over the wallpaper on a soft shadow.
        .shadow(color: .black.opacity(clear ? 0.45 : 0), radius: clear ? 6 : 0, y: 1)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            if !clear {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(LockPalette.stone950.opacity(0.25), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 27, style: .continuous).strokeBorder(Palette.ink.opacity(0.1), lineWidth: 1).padding(1)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Group {
                if let art = track?.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).grayscale(grayscale ? 1 : 0)
                } else {
                    LockPalette.purple.opacity(0.1)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(track?.artwork == nil ? 1 : 0.95)
            .opacity(track?.artwork == nil ? 1 : 0.95)
            VStack(alignment: .leading, spacing: 1) {
                if let track {
                    Text(track.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(track.artist).font(.system(size: 13, weight: .medium)).foregroundStyle(LockPalette.purple.opacity(0.75))
                } else {
                    Text("Not Playing").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(LockPalette.purple.opacity(0.5))
                }
            }
            .lineLimit(1)
            .padding(.leading, 16)
            Spacer(minLength: 8)
            LockEqualizer(playing: track?.isPlaying == true).padding(.trailing, 4)
        }
    }

    private var progress: some View {
        let fraction = track.map { $0.duration > 0 ? min(1, $0.elapsed / $0.duration) : 0 } ?? 0
        return HStack(spacing: 8) {
            Text(track.map { clock($0.elapsed) } ?? "-:--")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LockPalette.purple.opacity(0.25))
                    Capsule().fill(LockPalette.purple.opacity(0.75)).frame(width: max(6, geo.size.width * fraction))
                        .opacity(fraction > 0 ? 1 : 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    guard let track, track.duration > 0 else { return }
                    commands.seek(track.duration * Double(point.x / geo.size.width))
                }
            }
            .frame(height: 6)
            Text(track.map { $0.duration > 0 ? "-" + clock($0.duration - $0.elapsed) : "-:--" } ?? "-:--")
        }
        .font(.system(size: 10, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(LockPalette.purple.opacity(0.75))
        .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            control("shuffle", "Shuffle", size: 17, dim: true, action: commands.toggleShuffle)
            control("backward.fill", "Previous", size: 21, action: commands.previous)
            control(track?.isPlaying == true ? "pause.fill" : "play.fill", track?.isPlaying == true ? "Pause" : "Play", size: 27, action: commands.togglePlay)
            control("forward.fill", "Next", size: 21, action: commands.next)
            // Output indicator only: nothing can open an output picker on the Lock Screen.
            glyph(outputSymbol, size: 19, dim: true).accessibilityLabel("Output: \(output.name)")
        }
    }

    /// The HUD's device glyph (AirPods, headphones, AirPlay, display…), else this Mac or a speaker.
    private var outputSymbol: String {
        if let symbol = output.symbol { return symbol }
        if output.transport != kAudioDeviceTransportTypeBuiltIn { return "hifispeaker" }
        return output.name.contains("MacBook") ? "laptopcomputer" : "desktopcomputer"
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat, dim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(symbol, size: size, dim: dim).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func glyph(_ symbol: String, size: CGFloat, dim: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(dim ? AnyShapeStyle(LockPalette.purple.opacity(0.75)) : AnyShapeStyle(Palette.ink))
            .frame(width: 48, height: 46)
    }

    /// Speaker button (mute), level bar (dimmed while muted; dragging unmutes, like the volume keys).
    private func volumeRow(_ volume: LockVolume) -> some View {
        let muted = volume.muted.wrappedValue
        return HStack(spacing: 10) {
            Button { volume.muted.wrappedValue.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill").frame(width: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            GeometryReader { geo in
                LevelBar(value: volume.level.wrappedValue, tint: LockPalette.purple.opacity(0.85))
                    .opacity(muted ? 0.35 : 1)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged {
                        volume.level.wrappedValue = Double($0.location.x / geo.size.width)
                        if volume.muted.wrappedValue { volume.muted.wrappedValue = false }
                    })
            }
            .frame(height: 12)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(LockPalette.purple.opacity(0.75))
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .glass:
            ZStack {
                if gallery {
                    LockPalette.stone900.opacity(0.42)
                } else if #available(macOS 26, *) {
                    // Tahoe: Liquid Glass instead of the older blur material.
                    Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
                LockPalette.stone900.opacity(0.15)
            }
        case .dark:
            Color.black.opacity(0.72)
        case .artwork:
            ZStack {
                if let art = track?.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).blur(radius: 26).saturation(grayscale ? 0 : 1.3)
                } else {
                    LockPalette.stone900
                }
                Color.black.opacity(0.38)
            }
        case .clear:
            Color.clear
        }
    }
}

/// Five tiny bars: dots while idle, a soft wave while playing.
private struct LockEqualizer: View {
    var playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let h = playing ? 3 + 9 * abs(sin(t * (2.1 + Double(i) * 0.37) + Double(i))) : 2
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LockPalette.purple.opacity(playing ? 0.75 : 0.25))
                        .frame(width: 2, height: h)
                }
            }
            .frame(width: 20, height: 12)
        }
    }
}

// MARK: - Info row (focus, weather, battery, connectivity, calendar)

/// The inline row under the system clock ("Work · 24°" in the web demo), extended.
struct LockInfoRow: View {
    var data: LockScreenData
    var options: LockScreenOptions
    var now = Date()

    var body: some View {
        HStack(spacing: 20) {
            if options.showFocus, let focus = data.focus {
                item(focus.symbol) { Text(focus.name) }
            }
            if options.showWeather, let weather = data.weather {
                item(weather.symbol) {
                    Text(weather.temperature)
                    if options.weatherStyle == .detailed {
                        // Rain on the way replaces the condition word (the symbol still shows it).
                        if let rain = weather.rain {
                            Label(rain, systemImage: "drop.fill").labelStyle(.titleAndIcon).opacity(0.8)
                        } else {
                            Text(weather.condition).opacity(0.8)
                            if let p = weather.precipitation {
                                Label("\(Int((p * 100).rounded()))%", systemImage: "drop.fill").labelStyle(.titleAndIcon).opacity(0.8)
                            }
                        }
                    }
                }
            }
            if options.showBattery, let battery = data.battery {
                item(batterySymbol(battery)) {
                    Text("\(Int((battery.level * 100).rounded()))%")
                    if !battery.charging, let left = battery.timeToEmpty {
                        Text(duration(minutes: left) + " left").opacity(0.8)
                    }
                }
            }
            if options.showConnectivity {
                ForEach(data.devices) { device in
                    HStack(spacing: 6) {
                        Image(systemName: device.symbol).font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(device.tint.map { Color(nsColor: $0) } ?? LockPalette.purple.opacity(0.9))
                        if let level = device.battery {
                            BatteryRing(level: level, size: 16, lineWidth: 2)
                            Text("\(Int((level * 100).rounded()))%")
                        } else {
                            Text(device.name).lineLimit(1).layoutPriority(-1)
                        }
                    }
                }
            }
            if options.showCalendar, let event = data.event {
                HStack(spacing: 7) {
                    Circle().fill(event.tint(options.calendarColors, neutral: LockPalette.purple)).frame(width: 8, height: 8)
                    Text(event.title).lineLimit(1).layoutPriority(-1)
                    Text(eventTime(event, now: now)).opacity(0.8)
                }
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(LockPalette.purple.opacity(0.9))
        .lineLimit(1)  // a crowded row truncates instead of wrapping
    }

    private func item<Content: View>(_ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).symbolRenderingMode(.hierarchical)
            content()
        }
    }
}

// MARK: - Layout

/// What sits in the band between the system clock and the login controls: the info
/// row at the top, the Now Playing card at 66% of the band (58% of the screen).
struct LockScreenBand: View {
    var data: LockScreenData
    var options: LockScreenOptions
    var showsNowPlaying: Bool
    var volume: LockVolume?
    var commands: MediaCommands
    var now = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LockInfoRow(data: data, options: options, now: now)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                if showsNowPlaying {
                    NowPlayingWidget(
                        track: data.track, style: options.style, grayscale: options.grayscaleArtwork, output: data.output, volume: volume, commands: commands
                    )
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.66 + options.offset)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: showsNowPlaying)
        }
    }
}

/// The live band, refreshed every second (progress, countdowns, playback state).
struct LiveLockScreen: View {
    /// Previews fill missing data with samples; the real Lock Screen never does.
    var preview = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = LockScreenData.live(at: context.date)
            let data = preview ? live.filled(with: .sample) : live
            let options = LockScreenOptions.current
            LockScreenBand(
                data: data, options: options,
                showsNowPlaying: preview ? options.showNowPlaying && data.track != nil : NowPlayingActivity.shared.shows(data.track, at: context.date),
                volume: options.showVolume
                    ? LockVolume(
                        level: Binding(get: { SystemAudio.volume() ?? 0 }, set: { SystemAudio.setVolume($0) }),
                        muted: Binding(get: { SystemAudio.isMuted() }, set: { SystemAudio.setMuted($0) })
                    )
                    : nil,
                commands: NowPlayingState.shared.commands, now: context.date
            )
        }
    }
}

/// A whole lock screen for previews and the gallery: wallpaper, the system clock
/// (drawn by macOS on the real Lock Screen) and the band at its real position.
struct LockScreenComposition<Band: View>: View {
    var wallpaper: NSImage?
    var date = Date()
    @ViewBuilder var band: Band

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .top) {
                Group {
                    if let wallpaper {
                        Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.13, blue: 0.5), Color(red: 0.36, green: 0.2, blue: 0.62), Color(red: 0.55, green: 0.27, blue: 0.62)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .frame(width: geo.size.width, height: h)
                .clipped()
                VStack(spacing: h * 0.004) {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: h * 0.024, weight: .semibold))
                    Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .font(.system(size: h * 0.105, weight: .bold, design: .rounded))
                }
                .foregroundStyle(LockPalette.purple.opacity(0.88))
                .padding(.top, h * 0.085)
                band
                    .frame(width: min(geo.size.width, 760), height: h * 0.47)
                    .offset(y: h * 0.27)
            }
        }
    }
}

/// Renders `content` designed for `canvas` points, scaled to fit whatever space it gets.
struct ScaledCanvas<Content: View>: View {
    var canvas: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            content
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
