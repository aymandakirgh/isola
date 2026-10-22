import AppKit
import CoreAudio
import Observation
import SwiftUI

private let store = UserDefaults.standard
private func load<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }
private func loadRaw<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
    store.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
}

/// Media settings (persisted under `media.*`).
@MainActor @Observable
final class MediaPreferences {
    static let shared = MediaPreferences()

    var spectrogram: Bool = load("media.spectrogram", true) { didSet { store.set(spectrogram, forKey: "media.spectrogram"); MediaController.shared.syncLevels() } }
    var spectrogramStyle: SpectrogramStyle = SpectrogramStyle(rawValue: store.string(forKey: "media.spectrogramStyle") ?? "") ?? .bars {
        didSet { store.set(spectrogramStyle.rawValue, forKey: "media.spectrogramStyle") }
    }
    /// While this Focus is on (`focusMode`, "" for any), the wing shows its symbol instead of the spectrogram.
    var focusReplace: Bool = load("media.focusReplace", false) { didSet { store.set(focusReplace, forKey: "media.focusReplace"); MediaController.shared.syncLevels() } }
    var focusMode: String = load("media.focusMode", "") { didSet { store.set(focusMode, forKey: "media.focusMode"); MediaController.shared.syncLevels() } }
    /// Bars follow the real audio (system audio tap) instead of a canned animation.
    var liveWaveform: Bool = load("media.liveWaveform", false) { didSet { store.set(liveWaveform, forKey: "media.liveWaveform"); MediaController.shared.syncLevels() } }
    var grayscaleArtwork: Bool = load("media.grayscaleArtwork", false) { didSet { store.set(grayscaleArtwork, forKey: "media.grayscaleArtwork") } }
    var dimOnPause: Bool = load("media.dimOnPause", true) { didSet { store.set(dimOnPause, forKey: "media.dimOnPause") } }
    /// A soft specular highlight on the artwork; in the player it follows the pointer.
    var artworkGlare: Bool = load("media.artworkGlare", true) { didSet { store.set(artworkGlare, forKey: "media.artworkGlare") } }
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
    /// The volume row stays open when the player collapses and reopens.
    var keepVolumeOpen: Bool = load("media.keepVolumeOpen", false) { didSet { store.set(keepVolumeOpen, forKey: "media.keepVolumeOpen") } }
    /// The wing artwork card-flips when the track changes.
    var artworkFlip: Bool = load("media.artworkFlip", true) { didSet { store.set(artworkFlip, forKey: "media.artworkFlip") } }
    /// What the spectrogram, the gradient progress bar and the Colored outline are painted with.
    var colorStyle: MediaColorStyle = loadRaw("media.colorStyle", .gradient) {
        didSet { store.set(colorStyle.rawValue, forKey: "media.colorStyle"); MediaController.shared.restyle() }
    }
    /// The player's title badge, and the controls at the ends of its transport row (never the same one twice).
    var titleBadge: TitleBadge = loadRaw("media.titleBadge", .explicit) { didSet { store.set(titleBadge.rawValue, forKey: "media.titleBadge") } }
    var leftControl: PlayerControl = loadRaw("media.leftControl", .shuffle) {
        didSet { store.set(leftControl.rawValue, forKey: "media.leftControl"); if rightControl == leftControl { rightControl = oldValue } }
    }
    var rightControl: PlayerControl = loadRaw("media.rightControl", .repeat) {
        didSet { store.set(rightControl.rawValue, forKey: "media.rightControl"); if leftControl == rightControl { leftControl = oldValue } }
    }
    /// The title quick-peeks for `peekDuration` seconds when the track changes or playback resumes.
    var peekOnChange: Bool = load("media.peekOnChange", true) { didSet { store.set(peekOnChange, forKey: "media.peekOnChange") } }
    var peekDuration: Double = load("media.peekDuration", 2) { didSet { store.set(peekDuration, forKey: "media.peekDuration") } }
    /// The activity steps aside while the app that plays is in front, and comes back when it isn't.
    var hideWhileSourceActive: Bool = load("media.hideWhileSourceActive", false) {
        didSet { store.set(hideWhileSourceActive, forKey: "media.hideWhileSourceActive"); MediaController.shared.frontChanged() }
    }
    /// Where now-playing info comes from. This Mac's own choice (not synced): a player asks it for Automation.
    var source: MediaSourceChoice = loadRaw("media.source", .automatic) {
        didSet { store.set(source.rawValue, forKey: "media.source"); NowPlayingSources.shared.sourceChosen() }
    }

    /// The wing shows this Focus instead of the spectrogram.
    func showsFocus(_ focus: FocusState) -> Bool {
        focusReplace && focus.active && (focusMode.isEmpty || focusMode == focus.name)
    }

    /// `isolactl media.pref key=value`.
    func set(_ key: String, _ value: String) {
        let on = value == "1" || value == "true"
        switch key {
        case "spectrogram": spectrogram = on
        case "spectrogramStyle": spectrogramStyle = SpectrogramStyle(rawValue: value) ?? .bars
        case "focusReplace": focusReplace = on
        case "focusMode": focusMode = value == "any" ? "" : value
        case "liveWaveform": liveWaveform = on
        case "grayscaleArtwork": grayscaleArtwork = on
        case "dimOnPause": dimOnPause = on
        case "artworkGlare": artworkGlare = on
        case "hideNoteSymbol": hideNoteSymbol = on
        case "hideTitleExtras": hideTitleExtras = on
        case "idleSeconds": idleSeconds = Double(value) ?? 120
        case "excludeBrowsers": excludeBrowsers = on
        case "excludeInapt": excludeInapt = on
        case "gradientProgress": gradientProgress = on
        case "showTotalTime": showTotalTime = on
        case "keepVolumeOpen": keepVolumeOpen = on
        case "artworkFlip": artworkFlip = on
        case "colorStyle": colorStyle = MediaColorStyle(rawValue: value) ?? .gradient
        case "titleBadge": titleBadge = TitleBadge(rawValue: value) ?? .explicit
        case "leftControl": leftControl = PlayerControl(rawValue: value) ?? .shuffle
        case "rightControl": rightControl = PlayerControl(rawValue: value) ?? .repeat
        case "peekOnChange": peekOnChange = on
        case "peekDuration": peekDuration = Double(value) ?? 2
        case "hideWhileSourceActive": hideWhileSourceActive = on
        case "source": source = MediaSourceChoice(rawValue: value) ?? .automatic
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
    /// The expanded player shows the volume row in place of the progress bar.
    var volumeOpen = false
    /// Default output device and its volume (nil: no software volume), polled while the player is open.
    var output = HUDOutput.preset("speakers")
    var volume: Double?
    var muted = false
    /// Pointer over the expanded artwork (unit square) for the glare; nil leaves it at rest.
    var glarePoint: UnitPoint?
    /// One line in place of the progress bar for a few seconds (a Spotify command was refused).
    var notice: String?
    /// Offscreen gallery: Media › Player choices pinned for one shot, instead of the settings.
    var layout: PlayerLayout?

    func show(notice text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == text { notice = nil }
        }
    }

    func refreshOutput() {
        output = SystemAudio.output()
        volume = SystemAudio.canSetVolume() ? SystemAudio.volume() : nil
        muted = SystemAudio.isMuted()
    }

    /// Changes made here keep the volume HUD from popping up over the player.
    func setVolume(_ level: Double) {
        HUDModule.quietUntil = Date().addingTimeInterval(0.5)
        if muted { muted = false; SystemAudio.setMuted(false) }
        volume = min(1, max(0, level))
        SystemAudio.setVolume(volume ?? 0)
    }

    func toggleMute() {
        HUDModule.quietUntil = Date().addingTimeInterval(0.5)
        muted.toggle()
        SystemAudio.setMuted(muted)
    }
}

/// Turns source snapshots into `NowPlayingState` and runs the "media" live activity.
@MainActor
final class MediaController {
    static let shared = MediaController()

    private let state = NowPlayingState.shared
    private var idleTimer: Timer?
    /// The play → pause edge; "Keep after pausing" counts from here.
    private var pausedAt: Date?
    /// "Hide while the playing app is in front" sent the activity away, or kept a playing track's from starting: paused,
    /// it comes back within "Keep after pausing", whichever track the player moved on to meanwhile.
    private var hidden = false
    private var lastTrackKey = ""
    private var lastSnapshot: NowPlayingSnapshot?
    private var artworkID = ""
    /// The artwork's two dominant colours; `state.colors` has them as Media › Island › Colour paints them.
    private var artworkColors = NowPlayingState.shared.colors
    /// `isolactl media.play app=<bundle id>`: the simulated track claims that app (e.g. com.apple.podcasts);
    /// `episode=1` makes it a podcast episode, as Spotify's Web API reports one.
    var simulatedApp: String?
    var simulatedEpisode = false
    /// `isolactl media.front app=<bundle id>`: that app counts as the frontmost one (`app=-`: the real one again).
    var simulatedFront: String?

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

    static func appName(_ bundleID: String?) -> String? {
        guard let id = bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent
    }

    func apply(_ snapshot: NowPlayingSnapshot?) {
        var snapshot = snapshot
        if SimulatedPlayer.shared.active, let app = simulatedApp { snapshot?.bundleID = app }
        if SimulatedPlayer.shared.active, simulatedEpisode { snapshot?.episode = true }
        lastSnapshot = snapshot
        // Media without a title or artist (a bare stream, an untagged video) still counts while its app plays it.
        guard let s = snapshot, !(s.title.isEmpty && s.artist.isEmpty) || (s.bundleID != nil && (s.isPlaying || s.duration > 0)),
              !excluded(s.bundleID) else { return clear() }
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
            if let art = s.artwork {
                artworkColors = ArtworkColors.dominant(art)
                restyle()
            }
        }
        state.isPlaying = s.isPlaying
        state.duration = s.duration
        // A local seek or speed change already shows; give the source a second to report it.
        if trackChanged || Date().timeIntervalSince(state.adjustedAt) > 1 {
            state.elapsed = s.elapsed
            state.elapsedAt = s.timestamp
            // Sources report rate 0 while paused: keep the chosen speed until playback says otherwise.
            if s.isPlaying || s.bundleID != state.sourceBundleID { state.rate = s.rate > 0 ? s.rate : 1 }
        }
        state.shuffle = s.shuffle
        state.repeatMode = s.repeatMode
        state.sourceBundleID = s.bundleID
        state.isExplicit = s.explicit
        state.isEpisode = s.episode
        state.canLike = s.canLike
        state.liked = s.liked ?? false
        state.inTransition = s.inTransition
        state.audioFormat = s.audioFormat
        state.canCopyLink = s.link != nil || s.canFetchLink
        MediaUI.shared.link = s.link

        if trackChanged, MediaPreferences.shared.artworkFlip { withAnimation(.easeInOut(duration: 0.5)) { MediaUI.shared.flipped.toggle() } }
        lastTrackKey = key
        updateActivity(peek: trackChanged || resumed, wasPlaying: wasPlaying)
        syncLevels()
    }

    /// The artwork colours as Media › Island › Colour paints them.
    func restyle() {
        state.colors = MediaPreferences.shared.colorStyle.paint(artworkColors)
    }

    /// The audio tap only runs while it has something to draw (polls re-check a Focus that took the wing).
    func syncLevels() {
        let p = MediaPreferences.shared
        AudioLevels.shared.setActive(p.liveWaveform && p.spectrogram && !p.showsFocus(.shared) && state.isPlaying && !MediaUI.shared.offscreen)
    }

    private func clear() {
        guard state.hasTrack || Island.shared.isRunning("media") else { return }
        idleTimer?.invalidate()
        pausedAt = nil
        hidden = false
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
        if state.isPlaying { pausedAt = nil } else if wasPlaying { pausedAt = Date() }
        if sourceInFront { return hide() }
        if state.isPlaying {
            idleTimer?.invalidate()
            if !island.isRunning("media") || peek { island.start(MediaActivity.item(state: .shared, ui: .shared)) }
            let prefs = MediaPreferences.shared
            if peek, prefs.peekOnChange, island.current?.id == "media" { island.quickPeek(true, for: prefs.peekDuration) }
            return
        }
        // A track skipped while paused renews the item too: a swipe-up records its content key.
        if peek, island.isRunning("media") { island.update(MediaActivity.item(state: .shared, ui: .shared)) }
        // Polls repeat the paused state every second; only the play → pause edge arms the timer.
        guard wasPlaying, island.isRunning("media") else { return }
        linger()
    }

    /// Ends the paused activity once "Keep after pausing" runs out, counted from the pause.
    private func linger() {
        idleTimer?.invalidate()
        let left = Self.lingerLeft(idle: MediaPreferences.shared.idleSeconds, pausedAt: pausedAt)
        if left <= 0 { return Island.shared.end("media") }
        guard left.isFinite else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { _ in
            MainActor.assumeIsolated {
                if !NowPlayingState.shared.isPlaying { Island.shared.end("media") }
            }
        }
    }

    /// Seconds a paused activity has left under "Keep after pausing": infinity until the source stops, 0 once gone.
    static func lingerLeft(idle: Double, pausedAt: Date?, now: Date = Date()) -> TimeInterval {
        guard let pausedAt, idle != 0 else { return 0 }
        return idle < 0 ? .infinity : max(0, idle - now.timeIntervalSince(pausedAt))
    }

    /// "Hide while the playing app is in front": its own window already shows what plays.
    var sourceInFront: Bool {
        MediaPreferences.shared.hideWhileSourceActive
            && Self.hides(state, on: .shared, front: simulatedFront ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// The app that plays is in front, and the activity isn't swiped away for this track (until the next one): out of
    /// sight already, ending it would forget the swipe, and switching away would bring it back.
    static func hides(_ state: NowPlayingState, on island: Island, front: String?) -> Bool {
        state.sourceBundleID != nil && state.sourceBundleID == front && island.dismissed["media"] != MediaActivity.contentKey(state)
    }

    /// The activity leaves for its player; `hidden` brings it back once another app is in front. A playing track counts
    /// even when it never showed (started or resumed in the player, or the next one): only the hide keeps it away.
    private func hide() {
        idleTimer?.invalidate()
        if Island.shared.isRunning("media") || state.isPlaying { hidden = true }
        Island.shared.end("media")
    }

    /// Another app came forward (or the setting changed): the activity leaves for its player, or comes back without a peek.
    func frontChanged() {
        let island = Island.shared
        guard state.hasTrack else { return }
        if sourceInFront { return hide() }
        defer { hidden = false }
        guard !island.isRunning("media"),
              Self.comesBack(playing: state.isPlaying, hidden: hidden,
                             lingerLeft: Self.lingerLeft(idle: MediaPreferences.shared.idleSeconds, pausedAt: pausedAt)) else { return }
        island.start(MediaActivity.item(state: .shared, ui: .shared))
        if !state.isPlaying { linger() }
    }

    /// Back from behind its player as it would have stayed: playing, or a pause the hide sent away still within "Keep after
    /// pausing". A pause that ran out stays gone, also once the setting grows; so does one the hide never sent away.
    static func comesBack(playing: Bool, hidden: Bool, lingerLeft: TimeInterval) -> Bool { playing || hidden && lingerLeft > 0 }
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
        .inactive { !state.isPlaying }
        .contentKey(contentKey(state))
        .onSwipe { direction in
            switch direction {
            case .right: state.commands.next()
            case .left: state.commands.previous()
            case .up, .down: return false
            }
            return true
        }
        // Built as it opens, so it shows that moment's state.
        .contextMenu { currentEntries(state) }
    }

    /// What a swipe-up waits on: the next track brings the activity back.
    static func contentKey(_ s: NowPlayingState) -> String { "\(s.title)\u{1f}\(s.artist)" }

    /// The entries with the live app name, speed support and Media › Source.
    static func currentEntries(_ s: NowPlayingState) -> [MenuEntry] {
        entries(s, app: MediaController.appName(s.sourceBundleID), speed: SpeedMenu.available, source: MediaPreferences.shared.source)
    }

    /// Right-click on the activity: play or pause, skip (within the episode for podcasts), the link,
    /// the player app, playback speed where the source takes it, and Media › Source.
    static func entries(_ s: NowPlayingState, app: String?, speed: Bool, source: MediaSourceChoice) -> [MenuEntry] {
        let commands = s.commands
        var list: [MenuEntry] = [.action(s.isPlaying ? "Pause" : "Play", symbol: s.isPlaying ? "pause.fill" : "play.fill") { commands.togglePlay() }]
        list += s.skipsWithinEpisode
            ? [.action("Forward 30 Seconds", symbol: "goforward.30") { s.seek(to: s.currentElapsed() + 30) },
               .action("Back 15 Seconds", symbol: "gobackward.15") { s.seek(to: s.currentElapsed() - 15) }]
            : [.action("Next Track", symbol: "forward.fill") { commands.next() },
               .action("Previous Track", symbol: "backward.fill") { commands.previous() }]
        list.append(.separator)
        if s.canCopyLink { list.append(.action("Copy Link", symbol: "link") { commands.copyLink { _ in } }) }
        if let app { list.append(.action("Show in \(app)", symbol: "arrow.up.forward.app") { commands.openSource() }) }
        if speed {
            list.append(.submenu("Speed", symbol: "gauge.with.dots.needle.67percent", SpeedMenu.rates.map { rate in
                .action(SpeedMenu.label(rate), checked: s.rate == rate) { s.setRate(rate) }
            }))
        }
        list.append(.submenu("Source", symbol: "dot.radiowaves.left.and.right", MediaSourceChoice.allCases.map { choice in
            .action(choice.title, checked: choice == source) { MediaPreferences.shared.source = choice }
        }))
        return list
    }

    /// "Pause | Next Track | … | Speed › [0.5× · ✓1× · …]", for `isolactl media.menu.state` and the self-check.
    static func describe(_ entries: [MenuEntry]) -> String {
        entries.map { entry in
            switch entry {
            case let .action(title, _, _, checked, _, _): (checked ? "✓" : "") + title
            case let .submenu(title, _, children): "\(title) › [\(children.map { describe([$0]) }.joined(separator: " · "))]"
            case let .nowPlaying(title, _): title
            case .separator: "—"
            }
        }.joined(separator: " | ")
    }

    /// Runs the entry titled `title`, submenus included (`isolactl media.menu pick=<title>`); false if there is none.
    @discardableResult
    static func pick(_ title: String, in entries: [MenuEntry]) -> Bool {
        for entry in entries {
            switch entry {
            case let .action(t, _, _, _, _, run) where t == title:
                run()
                return true
            case let .submenu(_, _, children):
                if pick(title, in: children) { return true }
            default:
                continue
            }
        }
        return false
    }
}

@MainActor
enum MediaModule {
    static func start() {
        registerSettings()
        MediaController.shared.restyle()
        NowPlayingSources.shared.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MediaController.shared.frontChanged() }
        }
        registerDebug()
    }

    static func registerSettings() {
        SettingsRegistry.add("media", title: "Media", symbol: "music.note", order: 20, group: "liveActivities") { MediaSettingsView() }
    }

    private static func registerDebug() {
        let sim = SimulatedPlayer.shared
        Debug.on("media.play") { args in
            // blank=1: no title or artist, so the player falls back to the app's name.
            let blank = args["blank"] != nil
            MediaController.shared.simulatedApp = args["app"]
            MediaController.shared.simulatedEpisode = args["episode"] == "1"
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
        Debug.on("media.volume") { MediaUI.shared.volumeOpen = $0["on"] != "0" }
        Debug.on("media.like") { _ in NowPlayingState.shared.commands.toggleLike() }
        Debug.on("media.repeat") { _ in NowPlayingState.shared.commands.cycleRepeat() }
        Debug.on("media.notice") { MediaUI.shared.show(notice: $0["text"] ?? SpotifyWeb.problem(nil)) }
        Debug.on("media.open") { _ in NowPlayingState.shared.commands.openSource() }
        Debug.on("media.copylink") { _ in NowPlayingState.shared.commands.copyLink { _ in } }  // then: pbpaste
        Debug.on("media.state") { _ in
            let s = NowPlayingState.shared
            Debug.reply("source=\(NowPlayingSources.shared.source) chosen=\(MediaPreferences.shared.source.rawValue) playing=\(s.isPlaying) title=\(s.title) "
                + "app=\(s.sourceBundleID ?? "-") canLike=\(s.canLike) liked=\(s.liked) link=\(s.canCopyLink) format=\(s.audioFormat ?? "-") automix=\(s.inTransition) "
                + "explicit=\(s.isExplicit) repeat=\(s.repeatMode) podcast=\(s.isPodcast) colors=\(s.colors.count) hiddenForApp=\(MediaController.shared.sourceInFront) "
                + "spotify=\(SpotifyWeb.shared.summary)")
        }
        // Hide while the playing app is in front, without bringing an app forward: app=<bundle id>, or app=- for the real one.
        Debug.on("media.front") { args in
            MediaController.shared.simulatedFront = args["app"].flatMap { $0 == "-" ? nil : $0 }
            MediaController.shared.frontChanged()
        }
        // The right-click menu as it would open now; `media.menu pick=<title>` runs one of its entries.
        Debug.on("media.menu.state") { _ in Debug.reply(MediaActivity.describe(MediaActivity.currentEntries(.shared))) }
        Debug.on("media.menu") { args in
            if let title = args["pick"], !MediaActivity.pick(title, in: MediaActivity.currentEntries(.shared)) { NSLog("isola: no media menu entry %@", title) }
        }
        Debug.on("media.audio.state") { _ in
            let levels = AudioLevels.shared
            Debug.reply("running=\(levels.running) live=\(levels.live) heard=\(levels.heard.map(String.init) ?? "-")")
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

        // Outputs use the HUD's classification; plain speakers stay speakers.
        let speakers = HUDOutput.preset("speakers"), usb = HUDOutput(name: "USB Audio", transport: kAudioDeviceTransportTypeUSB)
        precondition(speakers.playerSymbol == "speaker.wave.2.fill" && speakers.playerName == "MacBook Pro Speakers", "built-in speakers")
        precondition(usb.playerSymbol == "hifispeaker.fill" && usb.playerName == "USB Audio", "external speakers")
        precondition(HUDOutput.preset("airpodspro").playerName == "AirPods Pro", "AirPods keep their name")
        precondition(HUDOutput(name: "Studio Display", transport: kAudioDeviceTransportTypeUSB).playerSymbol == "display", "Apple display speakers")
        precondition(HUDOutput(name: "EarPods", transport: kAudioDeviceTransportTypeUSB).playerSymbol == "earpods", "EarPods")

        // Every spectrogram style stays inside the 20 pt wing and visibly follows the levels.
        let wing = CGRect(x: 0, y: 0, width: 20, height: 20)
        for style in SpectrogramStyle.allCases {
            func box(_ levels: [Double]) -> CGRect { SpectrogramShape(style: style, levels: levels).path(in: wing).cgPath.boundingBoxOfPath }
            for levels in [[0.0, 0, 0, 0], [1, 1, 1, 1], [1, 0, 1, 0], [0, 1, 0, 1], [-0.2, 1.2, -0.2, 1.2]] {
                precondition(wing.contains(box(levels)), "\(style) \(levels) leaves the wing: \(box(levels))")
            }
            precondition(box([1, 1, 1, 1]).height > box([0, 0, 0, 0]).height + 6, "\(style) barely moves")
        }

        // "Keep after pausing" counts from the pause, also for an activity that comes back after its player was in front.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        precondition(MediaController.lingerLeft(idle: 120, pausedAt: t0, now: t0.addingTimeInterval(30)) == 90, "linger: what's left")
        precondition(MediaController.lingerLeft(idle: 120, pausedAt: t0, now: t0.addingTimeInterval(200)) == 0, "linger: ran out")
        precondition(MediaController.lingerLeft(idle: -1, pausedAt: t0, now: t0.addingTimeInterval(1e6)) == .infinity, "linger: until playback stops")
        precondition(MediaController.lingerLeft(idle: 0, pausedAt: t0) == 0 && MediaController.lingerLeft(idle: 120, pausedAt: nil) == 0, "linger: off, or never paused")

        // Hide while the playing app is in front: only for that app, and it leaves a track swiped away be (ending the activity
        // would forget the swipe, and switching away from the player would bring the track back); the next track hides as usual.
        let island = Island()
        let swiped = SimulatedPlayer.sampleState(index: 2, playing: true)
        island.start(MediaActivity.item(state: swiped, ui: MediaUI()))
        precondition(MediaController.hides(swiped, on: island, front: "com.apple.Music") && !MediaController.hides(swiped, on: island, front: "com.apple.Safari"),
                     "hide: for the player only")
        island.dismiss("media")
        precondition(!MediaController.hides(swiped, on: island, front: "com.apple.Music") && island.current == nil, "hide: a swiped-away track stays so")
        swiped.title = "Another Song"
        precondition(MediaController.hides(swiped, on: island, front: "com.apple.Music"), "hide: the next track is hidden like any other")
        // Once another app is in front: playing comes back, and so does a pause the hide sent away, until "Keep after pausing"
        // runs out; a pause it never sent away (one that ran out, with the setting grown since) stays gone.
        precondition(MediaController.comesBack(playing: true, hidden: false, lingerLeft: 0)
            && MediaController.comesBack(playing: false, hidden: true, lingerLeft: 30), "hide: back after the player")
        precondition(!MediaController.comesBack(playing: false, hidden: true, lingerLeft: 0)
            && !MediaController.comesBack(playing: false, hidden: false, lingerLeft: 30), "hide: a spent pause stays gone")

        // Colour: the gradient keeps both artwork colours; the others paint with one.
        let red = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1), blue = NSColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1)
        func rgb(_ c: NSColor) -> [CGFloat] { let s = c.usingColorSpace(.sRGB) ?? c; return [s.redComponent, s.greenComponent, s.blueComponent] }
        func hsb(_ c: NSColor) -> (sat: CGFloat, bri: CGFloat) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            (c.usingColorSpace(.sRGB) ?? c).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return (s, b)
        }
        precondition(MediaColorStyle.gradient.paint([red, blue]) == [red, blue], "colour: gradient as is")
        let mixed = MediaColorStyle.artwork.paint([red, blue])
        precondition(mixed.count == 1 && zip(rgb(mixed[0]), zip(rgb(red), rgb(blue))).allSatisfy { $0 > min($1.0, $1.1) && $0 < max($1.0, $1.1) },
                     "colour: artwork mixes the two \(rgb(mixed[0]))")
        let vivid = MediaColorStyle.colored.paint([red, blue])
        precondition(vivid.count == 1 && hsb(vivid[0]).bri >= 0.9 && hsb(vivid[0]).sat >= max(0.55, hsb(mixed[0]).sat), "colour: colored is bright and saturated")
        precondition(hsb(MediaColorStyle.colored.paint([NSColor(white: 0.4, alpha: 1), NSColor(white: 0.5, alpha: 1)])[0]).sat < 0.08, "colour: a grey cover stays grey")
        precondition(MediaColorStyle.monochrome.paint([red, blue]).map(rgb) == [rgb(NSColor(Palette.ink))], "colour: monochrome is ink")

        // Media › Source narrows what is read; Music's like is a favourite.
        precondition(MediaSourceChoice.automatic.readsSystem && MediaSourceChoice.automatic.players == ScriptPlayer.allCases
            && MediaSourceChoice.system.readsSystem && MediaSourceChoice.system.players.isEmpty
            && !MediaSourceChoice.music.readsSystem && MediaSourceChoice.spotify.players == [.spotify], "source choices")
        precondition(PlayerControl.like.title(source: "com.apple.Music") == "Favorite" && PlayerControl.like.symbol(source: "com.apple.Music") == "star"
            && PlayerControl.like.title(source: SpotifyWeb.bundleID) == "Like" && PlayerControl.like.symbol(source: nil) == "heart", "like or favourite")

        // The right-click menu: a song, then a podcast episode (skips within it, no app or speed).
        let song = SimulatedPlayer.sampleState(index: 0, playing: true)
        var toggled = false
        song.commands.togglePlay = { toggled = true }
        song.canCopyLink = true
        let songMenu = MediaActivity.entries(song, app: "Music", speed: true, source: .spotify)
        precondition(MediaActivity.describe(songMenu) == "Pause | Next Track | Previous Track | — | Copy Link | Show in Music | "
            + "Speed › [0.5× · 0.75× · ✓1× · 1.25× · 1.5× · 2×] | Source › [Automatic · System · Music · ✓Spotify]", "menu: \(MediaActivity.describe(songMenu))")
        precondition(MediaActivity.pick("Pause", in: songMenu) && toggled, "menu: pause")
        precondition(MediaActivity.pick("1.5×", in: songMenu) && song.rate == 1.5, "menu: speed, from its submenu")
        precondition(!MediaActivity.pick("Shuffle", in: songMenu), "menu: no such entry")
        let episode = SimulatedPlayer.sampleState(index: 1, playing: false)
        episode.isEpisode = true
        let episodeMenu = MediaActivity.entries(episode, app: nil, speed: false, source: .automatic)
        precondition(MediaActivity.describe(episodeMenu) == "Play | Forward 30 Seconds | Back 15 Seconds | — | Source › [✓Automatic · System · Music · Spotify]",
                     "podcast menu: \(MediaActivity.describe(episodeMenu))")
        let before = episode.elapsed
        precondition(MediaActivity.pick("Back 15 Seconds", in: episodeMenu) && abs(episode.elapsed - (before - 15)) < 0.01, "menu: 15 s back")
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
        let focus = FocusState()
        (focus.active, focus.name, focus.symbol, focus.tint) = (true, "Work", "briefcase.fill", .systemTeal)
        let focusItem = IslandItem(id: "media", kind: .liveActivity) {
            WingArtwork(state: playing, ui: ui).padding(.leading, 9)
        } trailing: {
            FocusWingSymbol(focus: focus).frame(width: 20, height: 20).padding(.trailing, 9)
        }
        Gallery.island("media-focus", item: focusItem)
        // Each spectrogram style, animated and with fixed bass-heavy "live" bands.
        let variants: [(String, [Float]?)] = [("", nil), ("-live", [0.95, 0.6, 0.35, 0.15])]
        for style in SpectrogramStyle.allCases {
            for (suffix, bands) in variants {
                let item = IslandItem(id: "media", kind: .liveActivity) {
                    WingArtwork(state: playing, ui: ui).padding(.leading, 9)
                } trailing: {
                    Spectrogram(state: playing, style: style, bands: bands).padding(.trailing, 9)
                }
                Gallery.island("media-style-\(style.rawValue)\(suffix)", item: item)
            }
        }
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
        let volumeUI = MediaUI()
        (volumeUI.offscreen, volumeUI.volumeOpen, volumeUI.output, volumeUI.volume) = (true, true, .preset("airpodspro"), 0.62)
        Gallery.island("media-expanded-volume", item: MediaActivity.item(state: playing, ui: volumeUI), expanded: true)
        let mutedUI = MediaUI()
        (mutedUI.offscreen, mutedUI.volumeOpen, mutedUI.output, mutedUI.volume, mutedUI.muted) = (true, true, .preset("homepod"), 0.4, true)
        Gallery.island("media-expanded-muted", item: MediaActivity.item(state: paused, ui: mutedUI), expanded: true)
        let hoverUI = MediaUI()
        (hoverUI.offscreen, hoverUI.glarePoint) = (true, UnitPoint(x: 0.78, y: 0.72))
        Gallery.island("media-expanded-glare-hover", item: MediaActivity.item(state: other, ui: hoverUI), expanded: true)
        Gallery.add("media-progress-gradient", size: CGSize(width: 420, height: 48)) {
            ProgressScrubber(state: other, gradient: true, totalTime: true)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
        // Entries named "*settings" are snapshotted through a hosting view by the core gallery.
        Gallery.add("media-settings", size: CGSize(width: 520, height: 1680)) {
            MediaSettingsView().background(Color(nsColor: .windowBackgroundColor))
        }

        // Source extras: like, copy link, stream format, AutoMix.
        NowPlayingExtras.selfCheck()
        let extras = SimulatedPlayer.sampleState(index: 2, playing: true)
        extras.canLike = true
        extras.liked = true
        extras.canCopyLink = true
        extras.audioFormat = "Dolby Atmos"
        Gallery.island("media-expanded-extras", item: MediaActivity.item(state: extras, ui: ui), expanded: true)
        let automix = SimulatedPlayer.sampleState(index: 0, playing: true)
        automix.inTransition = true
        Gallery.island("media-peek-automix", item: MediaActivity.item(state: automix, ui: ui), peeking: true)
        Gallery.island("media-expanded-automix", item: MediaActivity.item(state: automix, ui: ui), expanded: true)

        // Spotify through its Web API: liked, explicit, repeat one; an episode; a refused command.
        SpotifyWeb.selfCheck()
        let spotify = SimulatedPlayer.sampleState(index: 1, playing: true)
        (spotify.sourceBundleID, spotify.canLike, spotify.liked, spotify.repeatMode, spotify.canCopyLink) = ("com.spotify.client", true, true, 1, true)
        Gallery.island("media-expanded-spotify", item: MediaActivity.item(state: spotify, ui: ui), expanded: true)
        let episode = SimulatedPlayer.sampleState(index: 0, playing: true)
        (episode.sourceBundleID, episode.isEpisode, episode.title, episode.artist) = ("com.spotify.client", true, "Tides, Part 2", "Harbour Radio")
        (episode.canLike, episode.canCopyLink) = (true, true)
        Gallery.island("media-peek-spotify-episode", item: MediaActivity.item(state: episode, ui: ui), peeking: true)
        Gallery.island("media-expanded-spotify-episode", item: MediaActivity.item(state: episode, ui: ui), expanded: true)
        let refusedUI = MediaUI()
        (refusedUI.offscreen, refusedUI.notice) = (true, SpotifyWeb.problem((403, Data(#"{"error":{"reason":"PREMIUM_REQUIRED"}}"#.utf8))))
        Gallery.island("media-expanded-spotify-refused", item: MediaActivity.item(state: spotify, ui: refusedUI), expanded: true)

        // Media › Player: the format beside the title; like and copy link at the ends of the row
        // (Music's favourite star, Spotify's heart, dimmed where the source has neither).
        let formatUI = MediaUI()
        (formatUI.offscreen, formatUI.layout) = (true, PlayerLayout(badge: .format))
        Gallery.island("media-expanded-badge-format", item: MediaActivity.item(state: extras, ui: formatUI), expanded: true)
        let endsUI = MediaUI()
        (endsUI.offscreen, endsUI.layout) = (true, PlayerLayout(left: .like, right: .copy))
        Gallery.island("media-expanded-ends-music", item: MediaActivity.item(state: extras, ui: endsUI), expanded: true)
        Gallery.island("media-expanded-ends-spotify", item: MediaActivity.item(state: spotify, ui: endsUI), expanded: true)
        Gallery.island("media-expanded-ends-unavailable", item: MediaActivity.item(state: playing, ui: endsUI), expanded: true)

        // Media › Island › Colour, on the spectrogram (fixed bands) and the gradient progress bar.
        for style in MediaColorStyle.allCases {
            let tinted = SimulatedPlayer.sampleState(index: 2, playing: true)
            tinted.colors = style.paint(tinted.colors)
            let item = IslandItem(id: "media", kind: .liveActivity) {
                WingArtwork(state: tinted, ui: ui).padding(.leading, 9)
            } trailing: {
                Spectrogram(state: tinted, style: .mirrored, bands: [0.95, 0.75, 0.55, 0.35]).padding(.trailing, 9)
            }
            Gallery.island("media-colour-\(style.rawValue)", item: item, geometry: .notchPreview)
            Gallery.add("media-colour-\(style.rawValue)-progress", size: CGSize(width: 420, height: 48)) {
                ProgressScrubber(state: tinted, gradient: true, totalTime: true)
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }

        // The right-click menu, drawn like the status menu: a song, a podcast episode, and the song's submenus.
        let menuSong = SimulatedPlayer.sampleState(index: 2, playing: true)
        menuSong.canCopyLink = true
        let songEntries = MediaActivity.entries(menuSong, app: "Music", speed: true, source: .automatic)
        let menuEpisode = SimulatedPlayer.sampleState(index: 1, playing: false)
        menuEpisode.sourceBundleID = "com.apple.podcasts"
        let submenus = songEntries.compactMap { entry -> (String, [MenuEntry])? in
            guard case let .submenu(title, _, children) = entry else { return nil }
            return ("media-menu-\(title.lowercased())", children)
        }
        let menus = [("media-menu", songEntries), ("media-menu-podcast", MediaActivity.entries(menuEpisode, app: "Podcasts", speed: true, source: .automatic))] + submenus
        for (name, entries) in menus {
            Gallery.add(name, size: CGSize(width: 300, height: CGFloat(entries.count) * 25 + 40), hosted: true) {
                StatusMenuMock(entries: entries).background(Color(nsColor: .windowBackgroundColor))
            }
        }

        // Live waveform's audio access: not checked yet, allowed, and missing (with the way to System Settings).
        Gallery.add("media-audio-access-settings", size: CGSize(width: 520, height: 230)) {
            Form {
                Section("Live waveform") {
                    AudioAccessRow(levels: AudioLevels())
                    AudioAccessRow(levels: AudioLevels(heard: true))
                    AudioAccessRow(levels: AudioLevels(heard: false))
                }
            }
            .formStyle(.grouped)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
