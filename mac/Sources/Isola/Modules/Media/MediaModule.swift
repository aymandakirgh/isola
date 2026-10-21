import AppKit
import Observation
import SwiftUI

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }

/// Media settings (persisted under `media.*`).
@MainActor @Observable
final class MediaPreferences {
    static let shared = MediaPreferences()

    var spectrogram: Bool = load("media.spectrogram", true) { didSet { store.set(spectrogram, forKey: "media.spectrogram"); MediaController.shared.syncLevels() } }
    /// Bars follow the real audio (system audio tap) instead of a canned animation.
    var liveWaveform: Bool = load("media.liveWaveform", false) { didSet { store.set(liveWaveform, forKey: "media.liveWaveform"); MediaController.shared.syncLevels() } }
    var grayscaleArtwork: Bool = load("media.grayscaleArtwork", false) { didSet { store.set(grayscaleArtwork, forKey: "media.grayscaleArtwork") } }
    var dimOnPause: Bool = load("media.dimOnPause", true) { didSet { store.set(dimOnPause, forKey: "media.dimOnPause") } }
    var hideNoteSymbol: Bool = load("media.hideNoteSymbol", false) { didSet { store.set(hideNoteSymbol, forKey: "media.hideNoteSymbol") } }
    var hideTitleExtras: Bool = load("media.hideTitleExtras", false) { didSet { store.set(hideTitleExtras, forKey: "media.hideTitleExtras") } }
    /// Seconds the activity lingers after pausing; -1 keeps it until the source stops.
    var idleSeconds: Double = load("media.idleSeconds", 120) { didSet { store.set(idleSeconds, forKey: "media.idleSeconds") } }
    var excludeBrowsers: Bool = load("media.excludeBrowsers", false) { didSet { store.set(excludeBrowsers, forKey: "media.excludeBrowsers"); MediaController.shared.refresh() } }
    var excludeInapt: Bool = load("media.excludeInapt", true) { didSet { store.set(excludeInapt, forKey: "media.excludeInapt"); MediaController.shared.refresh() } }
    /// The progress bar is painted with the artwork colours.
    var gradientProgress: Bool = load("media.gradientProgress", false) { didSet { store.set(gradientProgress, forKey: "media.gradientProgress") } }
    /// The label after the progress bar shows the total duration instead of the time left (tap it to switch).
    var showTotalTime: Bool = load("media.showTotalTime", false) { didSet { store.set(showTotalTime, forKey: "media.showTotalTime") } }

    /// `isolactl media.pref key=value`.
    func set(_ key: String, _ value: String) {
        let on = value == "1" || value == "true"
        switch key {
        case "spectrogram": spectrogram = on
        case "liveWaveform": liveWaveform = on
        case "grayscaleArtwork": grayscaleArtwork = on
        case "dimOnPause": dimOnPause = on
        case "hideNoteSymbol": hideNoteSymbol = on
        case "hideTitleExtras": hideTitleExtras = on
        case "idleSeconds": idleSeconds = Double(value) ?? 120
        case "excludeBrowsers": excludeBrowsers = on
        case "excludeInapt": excludeInapt = on
        case "gradientProgress": gradientProgress = on
        case "showTotalTime": showTotalTime = on
        default: NSLog("isola: unknown media pref %@", key)
        }
    }
}

/// View-side state that is not part of the track itself.
@MainActor @Observable
final class MediaUI {
    static let shared = MediaUI()
    /// Toggled on track change; the artwork does a card-flip squeeze.
    var flipped = false
    /// Shareable link for the current track, when the source exposes one.
    var link: URL?
    /// Offscreen gallery: NSView-backed controls are drawn as plain symbols.
    var offscreen = false
}

/// Turns source snapshots into `NowPlayingState` and runs the "media" live activity.
@MainActor
final class MediaController {
    static let shared = MediaController()

    private let state = NowPlayingState.shared
    private var idleTimer: Timer?
    private var lastTrackKey = ""
    private var lastSnapshot: NowPlayingSnapshot?
    private var artworkID = ""
    /// `isolactl media.play app=<bundle id>`: the simulated track claims that app (e.g. com.apple.podcasts).
    var simulatedApp: String?

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
    ]
    /// Calls and chat apps whose audio is not "now playing" material.
    private static let inapt: Set<String> = [
        "com.apple.FaceTime", "com.apple.MobileSMS", "us.zoom.xos", "com.microsoft.teams2", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.apple.VoiceMemos",
    ]

    func excluded(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        let p = MediaPreferences.shared
        return (p.excludeBrowsers && Self.browsers.contains(id)) || (p.excludeInapt && Self.inapt.contains(id))
    }

    /// Re-apply the last snapshot (after a filter preference changes).
    func refresh() { apply(lastSnapshot) }

    /// Shown title and artist: untitled media takes its app's name, and the app fills an empty artist line.
    static func names(title: String, artist: String, app: String?) -> (title: String, artist: String) {
        title.isEmpty ? (app ?? "Now Playing", artist) : (title, artist.isEmpty ? app ?? "" : artist)
    }

    private static func appName(_ bundleID: String?) -> String? {
        guard let id = bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent
    }

    func apply(_ snapshot: NowPlayingSnapshot?) {
        var snapshot = snapshot
        if SimulatedPlayer.shared.active, let app = simulatedApp { snapshot?.bundleID = app }
        lastSnapshot = snapshot
        // Media without a title or artist (a bare stream, an untagged video) still counts while its app plays it.
        let untitled = snapshot.map { $0.title.isEmpty && $0.artist.isEmpty } ?? true
        guard let s = snapshot, !untitled || (s.bundleID != nil && (s.isPlaying || s.duration > 0)), !excluded(s.bundleID) else { return clear() }
        let key = "\(s.title)\u{1f}\(s.artist)\u{1f}\(s.album)"
        let trackChanged = !lastTrackKey.isEmpty && key != lastTrackKey
        let wasPlaying = state.isPlaying
        let resumed = !trackChanged && s.isPlaying && !wasPlaying && state.hasTrack

        let app = s.title.isEmpty || s.artist.isEmpty ? Self.appName(s.bundleID) : nil
        (state.title, state.artist) = Self.names(title: s.title, artist: s.artist, app: app)
        state.album = s.album
        if s.artworkID != artworkID || (state.artwork == nil && s.artwork != nil) {
            artworkID = s.artworkID
            state.artwork = s.artwork
            if let art = s.artwork { state.colors = ArtworkColors.dominant(art) }
        }
        state.isPlaying = s.isPlaying
        state.duration = s.duration
        // A local seek already moved the bar; give the source a second to report it.
        if trackChanged || Date().timeIntervalSince(state.seekedAt) > 1 {
            state.elapsed = s.elapsed
            state.elapsedAt = s.timestamp
        }
        // Sources report rate 0 while paused: keep the chosen speed until playback says otherwise.
        if s.isPlaying || s.bundleID != state.sourceBundleID { state.rate = s.rate > 0 ? s.rate : 1 }
        state.shuffle = s.shuffle
        state.repeatMode = s.repeatMode
        state.sourceBundleID = s.bundleID
        state.isExplicit = s.explicit
        MediaUI.shared.link = s.link

        if trackChanged { withAnimation(.easeInOut(duration: 0.5)) { MediaUI.shared.flipped.toggle() } }
        lastTrackKey = key
        updateActivity(peek: trackChanged || resumed, wasPlaying: wasPlaying)
        syncLevels()
    }

    /// The audio tap only runs while it has something to draw.
    func syncLevels() {
        let p = MediaPreferences.shared
        AudioLevels.shared.setActive(p.liveWaveform && p.spectrogram && state.isPlaying && !MediaUI.shared.offscreen)
    }

    private func clear() {
        guard state.hasTrack || Island.shared.isRunning("media") else { return }
        idleTimer?.invalidate()
        lastTrackKey = ""
        state.isPlaying = false
        state.title = ""
        state.artist = ""
        state.album = ""
        state.artwork = nil
        artworkID = ""
        MediaUI.shared.link = nil
        Island.shared.end("media")
        syncLevels()
    }

    private func updateActivity(peek: Bool, wasPlaying: Bool) {
        let island = Island.shared
        if state.isPlaying {
            idleTimer?.invalidate()
            if !island.isRunning("media") { island.start(MediaActivity.item(state: .shared, ui: .shared)) }
            if peek, island.current?.id == "media" { island.quickPeek(true, for: 2) }
            return
        }
        // Polls repeat the paused state every second; only the play → pause edge arms the timer.
        guard wasPlaying, island.isRunning("media") else { return }
        let idle = MediaPreferences.shared.idleSeconds
        if idle == 0 { return island.end("media") }
        if idle < 0 { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: idle, repeats: false) { _ in
            MainActor.assumeIsolated {
                if !NowPlayingState.shared.isPlaying { Island.shared.end("media") }
            }
        }
    }
}

/// The "media" live activity: artwork | spectrogram, marquee peek, full player.
@MainActor
enum MediaActivity {
    static func item(state: NowPlayingState, ui: MediaUI) -> IslandItem {
        IslandItem(id: "media", kind: .liveActivity, priority: 10) {
            WingArtwork(state: state, ui: ui).padding(.leading, 9)
        } trailing: {
            MediaTrailing(state: state).padding(.trailing, 9)
        }
        .peek(onHover: true) { MediaPeek(state: state) }
        .expanded(size: CGSize(width: 420, height: 162)) { ExpandedPlayer(state: state, ui: ui) }
        .onOptionTap { state.commands.togglePlay() }
        .onSwipe { direction in
            switch direction {
            case .right: state.commands.next()
            case .left: state.commands.previous()
            case .up, .down: return false
            }
            return true
        }
    }
}

@MainActor
enum MediaModule {
    static func start() {
        registerSettings()
        NowPlayingSources.shared.start()
        registerDebug()
    }

    static func registerSettings() {
        SettingsRegistry.add("media", title: "Media", symbol: "music.note", order: 20) { MediaSettingsView() }
    }

    private static func registerDebug() {
        let sim = SimulatedPlayer.shared
        Debug.on("media.play") { args in
            // blank=1: no title or artist, so the player falls back to the app's name.
            let blank = args["blank"] != nil
            MediaController.shared.simulatedApp = args["app"]
            sim.start(title: blank ? "" : args["title"], artist: blank ? "" : args["artist"], album: args["album"])
        }
        Debug.on("media.pause") { _ in if NowPlayingState.shared.isPlaying { NowPlayingState.shared.commands.togglePlay() } }
        Debug.on("media.resume") { _ in if !NowPlayingState.shared.isPlaying { NowPlayingState.shared.commands.togglePlay() } }
        Debug.on("media.next") { _ in NowPlayingState.shared.commands.next() }
        Debug.on("media.previous") { _ in NowPlayingState.shared.commands.previous() }
        // to=<seconds> or by=<±seconds>, through the same optimistic path as the scrubber.
        Debug.on("media.seek") { args in
            let s = NowPlayingState.shared
            s.seek(to: args["to"].flatMap(Double.init) ?? s.currentElapsed() + (args["by"].flatMap(Double.init) ?? 0))
        }
        Debug.on("media.end") { _ in sim.stop() }
        Debug.on("media.pref") { args in for (k, v) in args { MediaPreferences.shared.set(k, v) } }
        Debug.on("media.state") { _ in
            let s = NowPlayingState.shared
            Debug.reply("source=\(NowPlayingSources.shared.source) playing=\(s.isPlaying) title=\(s.title)")
        }
    }

    /// Runs with `Isola --gallery`: the player's own logic.
    static func selfCheck() {
        let s = NowPlayingState()
        s.duration = 200
        s.seek(to: -15)
        precondition(s.elapsed == 0, "seek clamps at the start: \(s.elapsed)")
        s.seek(to: 500)
        precondition(s.elapsed == 200, "seek clamps at the end: \(s.elapsed)")

        precondition(MediaController.names(title: "", artist: "", app: "Safari") == ("Safari", ""), "untitled → app name")
        precondition(MediaController.names(title: "", artist: "Band", app: "Safari") == ("Safari", "Band"), "untitled keeps its artist")
        precondition(MediaController.names(title: "Song", artist: "", app: "Safari") == ("Song", "Safari"), "app under an artist-less title")
        precondition(MediaController.names(title: "", artist: "", app: nil) == ("Now Playing", ""), "no app either")
        precondition(MediaController.names(title: "Song", artist: "Band", app: nil) == ("Song", "Band"), "tagged track untouched")
    }

    static func gallery() {
        registerSettings()
        TitleCleaner.selfCheck()
        BandAnalyzer.selfCheck()
        selfCheck()
        MediaUI.shared.offscreen = true

        let playing = SimulatedPlayer.sampleState(index: 0, playing: true)
        let paused = SimulatedPlayer.sampleState(index: 0, playing: false)
        let other = SimulatedPlayer.sampleState(index: 2, playing: true)
        let explicitPaused = SimulatedPlayer.sampleState(index: 1, playing: false)
        let ui = MediaUI()
        ui.offscreen = true

        Gallery.island("media-compact-playing", item: MediaActivity.item(state: playing, ui: ui))
        Gallery.island("media-compact-paused", item: MediaActivity.item(state: paused, ui: ui))
        Gallery.island("media-compact-playing-notch", item: MediaActivity.item(state: playing, ui: ui), geometry: .notchPreview)
        Gallery.island("media-peek", item: MediaActivity.item(state: other, ui: ui), peeking: true)
        Gallery.island("media-peek-notch", item: MediaActivity.item(state: playing, ui: ui), peeking: true, geometry: .notchPreview)
        let untitled = SimulatedPlayer.sampleState(index: 2, playing: true)
        (untitled.title, untitled.artist) = MediaController.names(title: "", artist: "", app: "Safari")
        Gallery.island("media-peek-untitled", item: MediaActivity.item(state: untitled, ui: ui), peeking: true)
        Gallery.island("media-expanded", item: MediaActivity.item(state: playing, ui: ui), expanded: true)
        Gallery.island("media-expanded-paused", item: MediaActivity.item(state: explicitPaused, ui: ui), expanded: true)
        let podcast = SimulatedPlayer.sampleState(index: 1, playing: true)
        podcast.sourceBundleID = "com.apple.podcasts"
        Gallery.island("media-peek-podcast", item: MediaActivity.item(state: podcast, ui: ui), peeking: true)
        Gallery.island("media-expanded-podcast", item: MediaActivity.item(state: podcast, ui: ui), expanded: true)
        Gallery.add("media-progress-gradient", size: CGSize(width: 420, height: 48)) {
            ProgressScrubber(state: other, gradient: true, totalTime: true)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
        // Entries named "*settings" are snapshotted through a hosting view by the core gallery.
        Gallery.add("media-settings", size: CGSize(width: 520, height: 560)) {
            MediaSettingsView().background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
