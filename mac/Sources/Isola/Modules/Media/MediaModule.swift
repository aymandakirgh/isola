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

    func apply(_ snapshot: NowPlayingSnapshot?) {
        lastSnapshot = snapshot
        guard let s = snapshot, !(s.title.isEmpty && s.artist.isEmpty), !excluded(s.bundleID) else { return clear() }
        let key = "\(s.title)\u{1f}\(s.artist)\u{1f}\(s.album)"
        let trackChanged = !lastTrackKey.isEmpty && key != lastTrackKey
        let wasPlaying = state.isPlaying
        let resumed = !trackChanged && s.isPlaying && !wasPlaying && state.hasTrack

        state.title = s.title
        state.artist = s.artist
        state.album = s.album
        if s.artworkID != artworkID || (state.artwork == nil && s.artwork != nil) {
            artworkID = s.artworkID
            state.artwork = s.artwork
            if let art = s.artwork { state.colors = ArtworkColors.dominant(art) }
        }
        state.isPlaying = s.isPlaying
        state.duration = s.duration
        state.elapsed = s.elapsed
        state.elapsedAt = s.timestamp
        state.rate = s.rate > 0 ? s.rate : state.rate
        state.shuffle = s.shuffle
        state.repeatMode = s.repeatMode
        state.sourceBundleID = s.bundleID
        state.isExplicit = s.explicit
        state.canLike = s.canLike
        state.liked = s.liked ?? false
        state.inTransition = s.inTransition
        state.audioFormat = s.audioFormat
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
            sim.start(title: args["title"], artist: args["artist"], album: args["album"])
        }
        Debug.on("media.pause") { _ in if NowPlayingState.shared.isPlaying { NowPlayingState.shared.commands.togglePlay() } }
        Debug.on("media.resume") { _ in if !NowPlayingState.shared.isPlaying { NowPlayingState.shared.commands.togglePlay() } }
        Debug.on("media.next") { _ in NowPlayingState.shared.commands.next() }
        Debug.on("media.previous") { _ in NowPlayingState.shared.commands.previous() }
        Debug.on("media.end") { _ in sim.stop() }
        Debug.on("media.like") { _ in NowPlayingState.shared.commands.toggleLike() }
        Debug.on("media.state") { _ in
            let s = NowPlayingState.shared
            Debug.reply("source=\(NowPlayingSources.shared.source) playing=\(s.isPlaying) title=\(s.title) app=\(s.sourceBundleID ?? "-") "
                + "canLike=\(s.canLike) liked=\(s.liked) format=\(s.audioFormat ?? "-") automix=\(s.inTransition)")
        }
    }

    static func gallery() {
        registerSettings()
        TitleCleaner.selfCheck()
        BandAnalyzer.selfCheck()
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
        Gallery.island("media-expanded", item: MediaActivity.item(state: playing, ui: ui), expanded: true)
        Gallery.island("media-expanded-paused", item: MediaActivity.item(state: explicitPaused, ui: ui), expanded: true)
        // Entries named "*settings" are snapshotted through a hosting view by the core gallery.
        Gallery.add("media-settings", size: CGSize(width: 520, height: 560)) {
            MediaSettingsView().background(Color(nsColor: .windowBackgroundColor))
        }

        // Source extras: like, stream format, AutoMix.
        NowPlayingExtras.selfCheck()
        let extras = SimulatedPlayer.sampleState(index: 2, playing: true)
        extras.canLike = true
        extras.liked = true
        extras.audioFormat = "Dolby Atmos"
        Gallery.island("media-expanded-extras", item: MediaActivity.item(state: extras, ui: ui), expanded: true)
        let automix = SimulatedPlayer.sampleState(index: 0, playing: true)
        automix.inTransition = true
        Gallery.island("media-peek-automix", item: MediaActivity.item(state: automix, ui: ui), peeking: true)
        Gallery.island("media-expanded-automix", item: MediaActivity.item(state: automix, ui: ui), expanded: true)
    }
}
