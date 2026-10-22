import AppKit

/// One reading of "what's playing" from any source.
struct NowPlayingSnapshot {
    var title = ""
    var artist = ""
    var album = ""
    var artwork: NSImage?
    /// Changes when the artwork changes (avoids recomputing colours every poll).
    var artworkID = ""
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var timestamp = Date()
    var rate: Double = 1
    var isPlaying = false
    var shuffle = false
    var repeatMode = 0  // 0 off, 1 one, 2 all
    var bundleID: String?
    var explicit = false
    var link: URL?
    /// No `link`, but the player can be asked for one when the user copies (Spotify, browser tabs).
    var canFetchLink = false
    /// The source takes a like; `liked` is nil when it does not say whether the track is liked.
    var canLike = false
    var liked: Bool?
    /// Apple Music AutoMix is crossfading into the next track.
    var inTransition = false
    /// "Lossless", "Hi-Res Lossless" or "Dolby Atmos".
    var audioFormat: String?
    /// A podcast episode in Spotify.
    var episode = false
}

/// Media › Source: where now-playing info comes from.
enum MediaSourceChoice: String, CaseIterable, Identifiable {
    /// MediaRemote, then the helper, then Music or Spotify where Automation already allows.
    case automatic
    /// MediaRemote and the helper only.
    case system
    /// That app alone, through AppleScript.
    case music, spotify

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var readsSystem: Bool { player == nil }
    /// The one app it names, if any.
    var player: ScriptPlayer? { self == .music ? .music : self == .spotify ? .spotify : nil }
    /// The scriptable players it may read, in order.
    var players: [ScriptPlayer] { player.map { [$0] } ?? (self == .automatic ? ScriptPlayer.allCases : []) }
}

/// Polls/receives now-playing info and routes media commands to whichever source is live:
/// MediaRemote first; AppleScript for Music/Spotify when MediaRemote stays silent
/// (macOS 15.4+ withholds it from unentitled apps); the simulated player in tests.
/// Media › Source can narrow that to the system alone, or to one player.
@MainActor
final class NowPlayingSources {
    static let shared = NowPlayingSources()

    enum Source { case none, mediaRemote, bridge, script(ScriptPlayer), simulated }
    private(set) var source: Source = .none
    private let remote = MediaRemote()
    private var lastScriptPoll = Date.distantPast
    private var scriptPolling = false
    /// A player just chosen in Media › Source, still to be asked for Automation (once it runs).
    private var askConsent: ScriptPlayer?
    /// What the snapshots do not carry: Automation consent per app (only ever checked; the one ask is
    /// `askConsent`'s) and a like known better than the source says (Music's AppleScript, a fresh click).
    private var last: NowPlayingSnapshot?
    private var trackKey = ""
    private var automation: [String: OSStatus] = [:]
    private var liked: (value: Bool, until: Date)?

    func start() {
        remote.register()
        for name in MediaRemote.notifications {
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NowPlayingSources.shared.poll() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { NowPlayingSources.shared.poll() }
        }
        MediaRemoteBridge.shared.onUpdate = { NowPlayingSources.shared.poll() }
        MediaRemoteBridge.shared.start()
        installCommands()
        poll()
    }

    func poll() {
        if SimulatedPlayer.shared.active { source = .simulated; return }
        // A player chosen in Media › Source is read on its own: no MediaRemote, no helper.
        guard MediaPreferences.shared.source.readsSystem else { return received(nil) }
        remote.fetch { snapshot in
            MainActor.assumeIsolated { NowPlayingSources.shared.received(snapshot) }
        }
    }

    /// Media › Source changed: a chosen player is asked for Automation once, then everything is read afresh.
    func sourceChosen() {
        askConsent = MediaPreferences.shared.source.player
        lastScriptPoll = .distantPast
        poll()
    }

    private func received(_ snapshot: NowPlayingSnapshot?) {
        guard !SimulatedPlayer.shared.active else { return }
        let choice = MediaPreferences.shared.source
        if choice.readsSystem {
            if let snapshot {
                source = .mediaRemote
                return deliver(snapshot)
            }
            // Direct MediaRemote is silent (blocked on macOS 15.4+): use the perl-hosted helper.
            if let bridged = MediaRemoteBridge.shared.latest {
                source = .bridge
                return deliver(bridged)
            }
        }
        let players = choice.players
        guard !players.isEmpty else {
            source = .none
            return deliver(nil)
        }
        // Chosen in Media › Source: the one prompt, on the script queue before any status read.
        if let player = askConsent, player.isRunning {
            askConsent = nil
            Scripting.queue.async { _ = Scripting.consent(player.bundleID, ask: true) }
        }
        // Nothing playing, or no helper. Ask the scriptable players, off the main thread and only
        // those Automation already allows: an idle Music or Spotify must not stall the UI or prompt.
        let interval: TimeInterval = if case .script = source { 0.8 } else { 3 }
        guard !scriptPolling, Date().timeIntervalSince(lastScriptPoll) > interval else { return }
        lastScriptPoll = Date()
        scriptPolling = true
        Scripting.queue.async {
            let found = players.lazy
                .filter { $0.isRunning && Scripting.consent($0.bundleID) == noErr }
                .compactMap { player in player.snapshot().map { (player, $0) } }
                .first
            DispatchQueue.main.async { MainActor.assumeIsolated { NowPlayingSources.shared.scripted(found) } }
        }
    }

    private func scripted(_ found: (ScriptPlayer, NowPlayingSnapshot)?) {
        scriptPolling = false
        let choice = MediaPreferences.shared.source
        // The helper may have spoken while the script ran; it wins, unless a player was chosen.
        guard !SimulatedPlayer.shared.active, !choice.readsSystem || MediaRemoteBridge.shared.latest == nil else { return }
        // The choice may have changed while the script ran.
        let found = found.flatMap { choice.players.contains($0.0) ? $0 : nil }
        source = found.map { .script($0.0) } ?? .none
        deliver(found?.1)
    }

    /// Adds the consent-gated extras, then hands the snapshot to the Media module.
    private func deliver(_ snapshot: NowPlayingSnapshot?) {
        last = snapshot
        SpotifyWeb.shared.follow(snapshot)
        guard var s = snapshot else { return MediaController.shared.apply(nil) }
        let key = "\(s.bundleID ?? "")\u{1f}\(s.title)\u{1f}\(s.artist)"
        if key != trackKey {
            trackKey = key
            liked = nil
            checkConsent(s.bundleID)
        }
        if let id = s.bundleID {
            // Liking in Music and copying from Spotify or a browser may ask for Automation once, on
            // the click; only an app the user denied loses the button.
            let consent = automation[id]
            let askable = consent == noErr || consent == OSStatus(errAEEventWouldRequireUserConsent)
            s.canFetchLink = s.link == nil && askable && (id == ScriptPlayer.spotify.bundleID || Browser(bundleID: id) != nil)
            // Music favourites go through AppleScript, whatever MediaRemote offers.
            if id == ScriptPlayer.music.bundleID { s.canLike = askable }
        }
        // Spotify's Web API, once connected: like, explicit, repeat one, episodes.
        SpotifyWeb.shared.merge(into: &s)
        if let liked, s.liked == nil || Date() < liked.until { s.liked = liked.value }
        MediaController.shared.apply(s)
    }

    /// The last snapshot again, with what Spotify's Web API just said.
    func redeliver() {
        if !SimulatedPlayer.shared.active { deliver(last) }
    }

    /// Off the main thread: what Automation already allows for the source app (never prompts),
    /// and Music's favourite flag when it may be read.
    private func checkConsent(_ bundleID: String?) {
        guard let id = bundleID, ScriptPlayer.allCases.contains(where: { $0.bundleID == id }) || Browser(bundleID: id) != nil else { return }
        let key = trackKey
        Scripting.queue.async {
            let consent = Scripting.consent(id)
            let favourite = consent == noErr && id == ScriptPlayer.music.bundleID ? ScriptPlayer.music.favourite() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let sources = NowPlayingSources.shared
                    sources.automation[id] = consent
                    if let favourite, key == sources.trackKey { sources.liked = (favourite, .distantFuture) }
                    if key == sources.trackKey { sources.deliver(sources.last) }
                }
            }
        }
    }

    /// Music: AppleScript favourite (the click may ask for Automation once). Spotify, once connected:
    /// its Web API library. Others: MediaRemote's LikeTrack, shown at once and corrected by the
    /// source within two seconds if it disagrees.
    private func toggleLike() {
        let state = NowPlayingState.shared
        let want = !state.liked
        liked = (want, Date().addingTimeInterval(2))
        state.liked = want
        if case .simulated = source { return SimulatedPlayer.shared.setLiked(want) }
        if SpotifyWeb.shared.like(want) { return }
        guard state.sourceBundleID == ScriptPlayer.music.bundleID else {
            if case .bridge = source { MediaRemoteBridge.shared.send("like \(want ? 1 : 0)") }
            return
        }
        let key = trackKey
        Scripting.queue.async {
            let result = ScriptPlayer.music.setFavourite(want)
            let consent = Scripting.consent(ScriptPlayer.music.bundleID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let sources = NowPlayingSources.shared
                    sources.automation[ScriptPlayer.music.bundleID] = consent
                    guard key == sources.trackKey else { return }
                    sources.liked = result.map { ($0, .distantFuture) }
                    sources.deliver(sources.last)
                }
            }
        }
    }

    /// Known links go straight to the pasteboard; Spotify and browsers are asked on the click.
    private func copyLink(_ done: @escaping (Bool) -> Void) {
        if let link = MediaUI.shared.link { return done(Self.copy(link)) }
        let state = NowPlayingState.shared
        guard let id = state.sourceBundleID else { return done(false) }
        let title = state.title
        Scripting.queue.async {
            let link = id == ScriptPlayer.spotify.bundleID ? ScriptPlayer.spotify.trackLink()
                : Browser(bundleID: id).flatMap { NowPlayingExtras.playingTab($0.tabs(), title: title) }.flatMap { URL(string: $0.url) }
            let consent = Scripting.consent(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NowPlayingSources.shared.automation[id] = consent
                    done(link.map(Self.copy) ?? false)
                }
            }
        }
    }

    private static func copy(_ link: URL) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    /// Brings the player forward. For a browser, first the tab that plays, but only where
    /// Automation already allows it; otherwise just the app, as before.
    private func openSource() {
        let state = NowPlayingState.shared
        guard let id = state.sourceBundleID else { return }
        guard let browser = Browser(bundleID: id) else { return Self.activate(id) }
        let title = state.title
        Scripting.queue.async {
            if Scripting.consent(id) == noErr, let tab = NowPlayingExtras.playingTab(browser.tabs(), title: title) { browser.focus(tab) }
            DispatchQueue.main.async { Self.activate(id) }
        }
    }

    private nonisolated static func activate(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func installCommands() {
        func route(sim: @escaping (SimulatedPlayer) -> Void, remote command: MediaRemote.Command?, script: ((ScriptPlayer) -> Void)?) -> () -> Void {
            {
                MainActor.assumeIsolated {
                    let sources = NowPlayingSources.shared
                    switch sources.source {
                    case .simulated: sim(SimulatedPlayer.shared)
                    case .mediaRemote: if let command { sources.remote.send(command) }
                    case .bridge: if let command { MediaRemoteBridge.shared.send("cmd \(command.rawValue)") }
                    case .script(let player): script?(player)
                    case .none: break
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { sources.lastScriptPoll = .distantPast; sources.poll() }
                }
            }
        }
        var commands = MediaCommands()
        commands.togglePlay = route(sim: { $0.togglePlay() }, remote: .togglePlayPause, script: { $0.perform("playpause") })
        commands.next = route(sim: { $0.skip(1) }, remote: .nextTrack, script: { $0.perform("next track") })
        commands.previous = route(sim: { $0.skip(-1) }, remote: .previousTrack, script: { $0.perform("previous track") })
        commands.toggleShuffle = route(sim: { $0.toggleShuffle() }, remote: .advanceShuffleMode, script: { $0.toggleShuffle() })
        // Spotify's Web API knows repeat one; the app's own repeat stays the fallback.
        let cycleRepeat = route(sim: { $0.cycleRepeat() }, remote: .advanceRepeatMode, script: { $0.cycleRepeat() })
        commands.cycleRepeat = { MainActor.assumeIsolated { if !SpotifyWeb.shared.cycleRepeat(fallback: cycleRepeat) { cycleRepeat() } } }
        commands.seek = { time in
            MainActor.assumeIsolated {
                let sources = NowPlayingSources.shared
                switch sources.source {
                case .simulated: SimulatedPlayer.shared.seek(time)
                case .mediaRemote: sources.remote.setElapsed(time)
                case .bridge: MediaRemoteBridge.shared.send("seek \(time)")
                case .script(let player): player.perform("set player position to \(time)")
                case .none: break
                }
            }
        }
        commands.setRate = { rate in
            MainActor.assumeIsolated {
                let sources = NowPlayingSources.shared
                switch sources.source {
                case .simulated: SimulatedPlayer.shared.setRate(rate)
                case .mediaRemote: sources.remote.send(.changePlaybackRate, options: ["kMRMediaRemoteOptionPlaybackRate": rate])
                case .bridge: MediaRemoteBridge.shared.send("rate \(rate)")
                default: break  // Music/Spotify scripting has no rate control
                }
            }
        }
        commands.openSource = { MainActor.assumeIsolated { NowPlayingSources.shared.openSource() } }
        commands.toggleLike = { MainActor.assumeIsolated { NowPlayingSources.shared.toggleLike() } }
        commands.copyLink = { done in MainActor.assumeIsolated { NowPlayingSources.shared.copyLink(done) } }
        NowPlayingState.shared.commands = commands
    }

    /// The simulated player took over or let go.
    func simulationChanged() {
        source = SimulatedPlayer.shared.active ? .simulated : .none
        if !SimulatedPlayer.shared.active { poll() }
    }
}

// MARK: - MediaRemote (private framework, loaded at runtime)

final class MediaRemote {
    static let notifications = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]

    /// Values as MRMediaRemoteCopyCommandDescription names them.
    enum Command: UInt32 {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
        case advanceShuffleMode = 6, advanceRepeatMode = 7, changePlaybackRate = 19
    }

    private typealias Register = @convention(c) (DispatchQueue) -> Void
    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias PlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias PIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias SendFn = @convention(c) (UInt32, NSDictionary?) -> Bool
    private typealias ElapsedFn = @convention(c) (Double) -> Void

    private let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    private var artworkKey = ""
    private var artwork: NSImage?

    private func fn<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    func register() { fn("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self)?(.main) }

    func send(_ command: Command, options: [String: Any]? = nil) {
        _ = fn("MRMediaRemoteSendCommand", as: SendFn.self)?(command.rawValue, options as NSDictionary?)
    }

    func setElapsed(_ time: TimeInterval) { fn("MRMediaRemoteSetElapsedTime", as: ElapsedFn.self)?(time) }

    /// Calls back on the main queue; nil when MediaRemote reports nothing.
    func fetch(_ done: @escaping (NowPlayingSnapshot?) -> Void) {
        guard let info = fn("MRMediaRemoteGetNowPlayingInfo", as: InfoFn.self) else { return done(nil) }
        let playing = fn("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: PlayingFn.self)
        let pid = fn("MRMediaRemoteGetNowPlayingApplicationPID", as: PIDFn.self)
        info(.main) { dict in
            guard let dict = dict as? [String: Any], !dict.isEmpty else { return done(nil) }
            let finish: (Bool?, Int32) -> Void = { isPlaying, processID in
                done(self.snapshot(dict, playing: isPlaying, pid: processID))
            }
            guard let playing else { return finish(nil, 0) }
            playing(.main) { isPlaying in
                guard let pid else { return finish(isPlaying, 0) }
                pid(.main) { finish(isPlaying, $0) }
            }
        }
    }

    private func snapshot(_ d: [String: Any], playing: Bool?, pid: Int32) -> NowPlayingSnapshot {
        func num(_ key: String) -> Double? { (d["kMRMediaRemoteNowPlayingInfo\(key)"] as? NSNumber)?.doubleValue }
        var s = NowPlayingSnapshot()
        s.title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        s.artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        s.album = d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        s.duration = num("Duration") ?? 0
        s.elapsed = num("ElapsedTime") ?? 0
        s.timestamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
        let rate = num("PlaybackRate") ?? 0
        s.rate = rate > 0 ? rate : 1
        s.isPlaying = playing ?? (rate > 0)
        // MediaRemote modes: 1 off, 2/3 on (albums/songs); repeat 2 one, 3 all.
        s.shuffle = (num("ShuffleMode") ?? 1) >= 2
        s.repeatMode = switch Int(num("RepeatMode") ?? 1) { case 2: 1; case 3: 2; default: 0 }
        s.explicit = (num("IsExplicitTrack") ?? 0) > 0
        s.inTransition = (num("IsInTransition") ?? 0) > 0
        s.link = NowPlayingExtras.appleMusicLink(d["kMRMediaRemoteNowPlayingInfoiTunesStoreSubscriptionAdamIdentifier"],
                                                 d["kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier"])
        if pid > 0 { s.bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
        if let data = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            let key = (d["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] as? String) ?? "\(s.title)|\(s.album)|\(data.count)"
            if key != artworkKey { artworkKey = key; artwork = NSImage(data: data) }
            s.artwork = artwork
            s.artworkID = key
        }
        return s
    }
}

// MARK: - AppleScript (Music, Spotify, browsers)

/// All AppleScript runs on one serial queue, off the main thread: an Apple Event can take
/// seconds, and the first one to an app may wait on the Automation prompt.
enum Scripting {
    static let queue = DispatchQueue(label: "app.isola.applescript", qos: .userInitiated)
    static let field = "␟", record = "␞"
    private static var scripts: [String: NSAppleScript] = [:]

    /// Call on `queue`.
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        let script = scripts[source] ?? NSAppleScript(source: source)
        scripts[source] = script
        var error: NSDictionary?
        return script?.executeAndReturnError(&error)
    }

    /// Automation consent for an app: noErr allowed, errAEEventNotPermitted denied, errAEEventWouldRequireUserConsent
    /// not asked yet, procNotFound not running. Never prompts unless `ask` (a user's explicit choice), and then only
    /// if never answered. May block (until the prompt is answered): call on `queue`.
    static func consent(_ bundleID: String, ask: Bool = false) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
}

/// Reading Music/Spotify when MediaRemote says nothing. Every method runs scripts: call on `Scripting.queue`.
enum ScriptPlayer: CaseIterable {
    case music, spotify

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    private static var artworkCache: [String: NSImage] = [:]

    private var statusScript: String {
        let s = Scripting.field
        switch self {
        case .music:
            return """
            tell application id "com.apple.Music"
              set st to player state as string
              if st is "stopped" then return "stopped"
              set t to current track
              return st & "\(s)" & (name of t) & "\(s)" & (artist of t) & "\(s)" & (album of t) & "\(s)" & (duration of t) & "\(s)" & (player position) & "\(s)" & (shuffle enabled as string) & "\(s)" & (song repeat as string) & "\(s)" & (persistent ID of t)
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
              set st to player state as string
              if st is "stopped" then return "stopped"
              set t to current track
              return st & "\(s)" & (name of t) & "\(s)" & (artist of t) & "\(s)" & (album of t) & "\(s)" & ((duration of t) / 1000) & "\(s)" & (player position) & "\(s)" & (shuffling as string) & "\(s)" & (repeating as string) & "\(s)" & (id of t) & "\(s)" & (artwork url of t)
            end tell
            """
        }
    }

    /// Only call while the app runs: `tell` would otherwise launch it.
    func snapshot() -> NowPlayingSnapshot? {
        guard isRunning, let out = Scripting.run(statusScript)?.stringValue else { return nil }
        let f = out.components(separatedBy: Scripting.field)
        guard f.count >= 9 else { return nil }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var s = NowPlayingSnapshot()
        s.isPlaying = f[0] == "playing"
        s.title = f[1]
        s.artist = f[2]
        s.album = f[3]
        s.duration = number(f[4])
        s.elapsed = number(f[5])
        s.shuffle = f[6] == "true"
        s.bundleID = bundleID
        s.artworkID = f[8]
        switch self {
        case .music:
            s.repeatMode = f[7] == "one" ? 1 : f[7] == "all" ? 2 : 0
            if let cached = Self.artworkCache[f[8]] {
                s.artwork = cached
            } else if let data = Scripting.run("tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track")?.data,
                      let image = NSImage(data: data) {
                Self.artworkCache = [f[8]: image]
                s.artwork = image
            }
        case .spotify:
            s.repeatMode = f[7] == "true" ? 2 : 0
            s.link = NowPlayingExtras.spotifyLink(f[8])
            s.episode = f[8].hasPrefix("spotify:episode:")
            if f.count > 9, let url = URL(string: f[9]) {
                if let cached = Self.artworkCache[f[9]] {
                    s.artwork = cached
                } else {
                    Self.fetchArtwork(url, key: f[9])
                }
            }
        }
        return s
    }

    private static func fetchArtwork(_ url: URL, key: String) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Scripting.queue.async {
                artworkCache = [key: image]
                DispatchQueue.main.async { MainActor.assumeIsolated { NowPlayingSources.shared.poll() } }
            }
        }.resume()
    }

    /// A control the user pressed: runs even before Automation was granted (that is when macOS asks).
    func perform(_ command: String) {
        Scripting.queue.async {
            guard isRunning else { return }
            Scripting.run("tell application id \"\(bundleID)\" to \(command)")
        }
    }

    /// Music's favourite flag: `favorited`, formerly `loved`; both are the pLov property.
    func favourite() -> Bool? {
        Scripting.run("tell application id \"com.apple.Music\" to return («class pLov» of current track) as string")?.stringValue.map { $0 == "true" }
    }

    /// Sets the favourite flag and reads it back (nil when Music refused, e.g. a radio stream).
    func setFavourite(_ on: Bool) -> Bool? {
        Scripting.run("""
        tell application id "com.apple.Music"
          set «class pLov» of current track to \(on)
          return («class pLov» of current track) as string
        end tell
        """)?.stringValue.map { $0 == "true" }
    }

    /// Spotify's share link for the current track or episode.
    func trackLink() -> URL? {
        Scripting.run("tell application id \"com.spotify.client\" to return id of current track")?.stringValue.flatMap(NowPlayingExtras.spotifyLink)
    }

    func toggleShuffle() {
        perform(self == .music ? "set shuffle enabled to not shuffle enabled" : "set shuffling to not shuffling")
    }

    func cycleRepeat() {
        switch self {
        case .music:
            perform("""
            if song repeat is off then
              set song repeat to all
            else if song repeat is all then
              set song repeat to one
            else
              set song repeat to off
            end if
            """)
        case .spotify:
            perform("set repeating to not repeating")
        }
    }
}

/// A tab as a browser's AppleScript lists it.
struct BrowserTab: Equatable {
    var window: Int
    var index: Int
    var active: Bool
    var title: String
    var url: String
}

/// Browsers whose dictionary lists windows › tabs with titles and URLs (Safari, Chrome's
/// dictionary shared by Edge, Brave, Arc, Vivaldi and Opera, and Dia's own, which has
/// `isFocused` tabs and a `focus` command). Methods run scripts: call on `Scripting.queue`.
struct Browser {
    let bundleID: String
    private var isSafari: Bool { bundleID == "com.apple.Safari" }
    private var isDia: Bool { bundleID == "company.thebrowser.dia" }

    init?(bundleID: String) {
        let scriptable = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
                          "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
        guard scriptable.contains(bundleID) else { return nil }
        self.bundleID = bundleID
    }

    /// Every tab of every window, front window first. «class acTI» is Chrome's `active tab index`.
    func tabs() -> [BrowserTab] {
        let f = Scripting.field, r = Scripting.record
        let title = isSafari ? "name" : "title"
        let active = isSafari ? "set activeIndex to index of current tab of window w"
            : isDia ? """
              set focused to isFocused of every tab of window w
              repeat with k from 1 to count of focused
                if item k of focused then set activeIndex to k
              end repeat
              """
            : "set activeIndex to «class acTI» of window w"
        let listing = Scripting.run("""
        tell application id "\(bundleID)"
          set out to ""
          repeat with w from 1 to count of windows
            try
              set activeIndex to 0
              try
                \(active)
              end try
              set titles to \(title) of every tab of window w
              set urls to URL of every tab of window w
              repeat with t from 1 to count of titles
                set out to out & w & "\(f)" & t & "\(f)" & (t = activeIndex) & "\(f)" & ((item t of titles) as text) & "\(f)" & ((item t of urls) as text) & "\(r)"
              end repeat
            end try
          end repeat
          return out
        end tell
        """)
        return listing?.stringValue.map(Self.parse) ?? []
    }

    static func parse(_ listing: String) -> [BrowserTab] {
        listing.components(separatedBy: Scripting.record).compactMap { line in
            let f = line.components(separatedBy: Scripting.field)
            guard f.count == 5, let window = Int(f[0]), let index = Int(f[1]) else { return nil }
            return BrowserTab(window: window, index: index, active: f[2] == "true", title: f[3], url: f[4])
        }
    }

    /// Selects the tab, then raises its window (raising first would renumber the windows). Dia's
    /// `focus` brings the window forward itself, so raising "window w" after it would hit another.
    func focus(_ tab: BrowserTab) {
        let w = tab.window, t = tab.index
        if isDia { Scripting.run("tell application id \"\(bundleID)\" to focus tab \(t) of window \(w)"); return }
        let select = isSafari ? "set current tab of window \(w) to tab \(t) of window \(w)"
            : bundleID == "company.thebrowser.Browser" ? "tell tab \(t) of window \(w) to select"
            : "set «class acTI» of window \(w) to \(t)"
        Scripting.run("""
        tell application id "\(bundleID)"
          try
            \(select)
          end try
          try
            set index of window \(w) to 1
          end try
        end tell
        """)
    }
}

/// Links and labels derived from what the sources report.
enum NowPlayingExtras {
    /// Apple Music catalogue ID (number or string, 0 for local files) → its song page;
    /// music.apple.com redirects to the listener's storefront.
    static func appleMusicLink(_ ids: Any?...) -> URL? {
        let id = ids.lazy.compactMap { ($0 as? NSNumber)?.int64Value ?? ($0 as? String).flatMap { Int64($0) } }.first { $0 > 0 }
        return id.flatMap { URL(string: "https://music.apple.com/song/\($0)") }
    }

    /// "spotify:track:ID" or "spotify:episode:ID" → open.spotify.com (local files and ads have none).
    static func spotifyLink(_ uri: String) -> URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" || parts[1] == "episode" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }

    /// MediaRemote audio tiers: 2 Lossless, 3 HighResolutionLossless, 4 Spatial; rendering mode 5 DolbyAtmos.
    static func audioFormat(tier: Int?, rendering: Int?) -> String? {
        if rendering == 5 || tier == 4 { return "Dolby Atmos" }
        return tier == 3 ? "Hi-Res Lossless" : tier == 2 ? "Lossless" : nil
    }

    /// The tab that plays `title`: YouTube (or YouTube Music) with the title, then any tab with
    /// the title, then a YouTube tab; ties go to an active tab, then to the frontmost window.
    static func playingTab(_ tabs: [BrowserTab], title: String) -> BrowserTab? {
        func rank(_ tab: BrowserTab) -> (Int, Int, Int) {
            let host = URL(string: tab.url)?.host?.lowercased() ?? ""
            let youtube = host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
            let titled = !title.isEmpty && tab.title.localizedCaseInsensitiveContains(title)
            return ((titled ? 2 : 0) + (youtube ? 1 : 0), tab.active ? 1 : 0, -tab.window)
        }
        return tabs.filter { rank($0).0 > 0 }.max { rank($0) < rank($1) }
    }

    static func selfCheck() {
        precondition(appleMusicLink(NSNumber(value: 1440841766))?.absoluteString == "https://music.apple.com/song/1440841766")
        precondition(appleMusicLink(0, "1440841766")?.absoluteString == "https://music.apple.com/song/1440841766")
        precondition(appleMusicLink(nil, 0) == nil)
        precondition(spotifyLink("spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.absoluteString == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        precondition(spotifyLink("spotify:episode:512ojhOuo1ktJprKbVcKyQ")?.absoluteString == "https://open.spotify.com/episode/512ojhOuo1ktJprKbVcKyQ")
        precondition(spotifyLink("spotify:local:Artist:Album:Song:215") == nil && spotifyLink("spotify:ad:0000") == nil)
        precondition(audioFormat(tier: 2, rendering: 1) == "Lossless" && audioFormat(tier: 3, rendering: nil) == "Hi-Res Lossless")
        precondition(audioFormat(tier: 4, rendering: nil) == "Dolby Atmos" && audioFormat(tier: 1, rendering: 5) == "Dolby Atmos")
        precondition(audioFormat(tier: 1, rendering: 1) == nil && audioFormat(tier: nil, rendering: nil) == nil)
        let f = Scripting.field, r = Scripting.record
        let listing = [
            "1\(f)1\(f)true\(f)Inbox\(f)https://mail.example.com",
            "1\(f)2\(f)false\(f)(2) Glass Harbour - YouTube\(f)https://www.youtube.com/watch?v=b",
            "2\(f)1\(f)true\(f)YouTube Music\(f)https://music.youtube.com/watch?v=c",
            "2\(f)2\(f)false\(f)Velvet Static • Oro Hills\(f)https://soundcloud.com/oro/velvet",
            "garbage",
        ].joined(separator: r) + r
        let tabs = Browser.parse(listing)
        precondition(tabs.count == 4 && tabs[1] == BrowserTab(window: 1, index: 2, active: false, title: "(2) Glass Harbour - YouTube", url: "https://www.youtube.com/watch?v=b"))
        precondition(playingTab(tabs, title: "glass harbour")?.url == "https://www.youtube.com/watch?v=b")
        precondition(playingTab(tabs, title: "Velvet Static")?.url == "https://soundcloud.com/oro/velvet")
        precondition(playingTab(tabs, title: "Night Ferries")?.url == "https://music.youtube.com/watch?v=c")
        precondition(playingTab(Array(tabs.prefix(1)), title: "Night Ferries") == nil)
        precondition(Browser(bundleID: "company.thebrowser.dia") != nil && Browser(bundleID: "org.mozilla.firefox") == nil, "Dia scripts like Chrome; Firefox can't")
    }
}

// MARK: - Simulated player (headless testing: `isolactl media.play`)

@MainActor
final class SimulatedPlayer {
    static let shared = SimulatedPlayer()

    struct Track {
        var title: String
        var artist: String
        var album: String
        var top: NSColor
        var bottom: NSColor
        var duration: TimeInterval
    }

    static let tracks: [Track] = [
        Track(title: "Glass Harbour", artist: "Lumen Atlas", album: "Night Ferries",
              top: NSColor(srgbRed: 0.83, green: 0.62, blue: 0.63, alpha: 1), bottom: NSColor(srgbRed: 0.42, green: 0.35, blue: 0.42, alpha: 1), duration: 214),
        Track(title: "Velvet Static", artist: "Oro Hills", album: "Satellite Summer",
              top: NSColor(srgbRed: 0.45, green: 0.45, blue: 0.84, alpha: 1), bottom: NSColor(srgbRed: 0.1, green: 0.13, blue: 0.23, alpha: 1), duration: 187),
        Track(title: "Palm Lines (feat. Mira) - Remastered 2024", artist: "Coastal Bloom", album: "Ocean Hours",
              top: NSColor(srgbRed: 0.89, green: 0.5, blue: 0.58, alpha: 1), bottom: NSColor(srgbRed: 0.29, green: 0.13, blue: 0.36, alpha: 1), duration: 241),
    ]

    private(set) var active = false
    private var index = 0
    private var custom: Track?
    private var playing = true
    private var elapsed: TimeInterval = 0
    private var elapsedAt = Date()
    private var rate = 1.0
    private var shuffle = false
    private var repeatMode = 0
    private var liked = false

    private var track: Track { custom ?? Self.tracks[index] }

    func start(title: String?, artist: String?, album: String?) {
        active = true
        index = 0
        let base = Self.tracks[0]
        custom = title == nil && artist == nil && album == nil ? nil
            : Track(title: title ?? base.title, artist: artist ?? base.artist, album: album ?? base.album, top: base.top, bottom: base.bottom, duration: base.duration)
        playing = true
        elapsed = 0
        elapsedAt = Date()
        NowPlayingSources.shared.simulationChanged()
        push()
    }

    func stop() {
        active = false
        MediaController.shared.apply(nil)
        NowPlayingSources.shared.simulationChanged()
    }

    private func freeze() {
        if playing { elapsed += Date().timeIntervalSince(elapsedAt) * rate }
        elapsedAt = Date()
    }

    func togglePlay() { freeze(); playing.toggle(); push() }
    func skip(_ step: Int) { custom = nil; index = (index + step + Self.tracks.count) % Self.tracks.count; elapsed = 0; elapsedAt = Date(); playing = true; liked = false; push() }
    func seek(_ time: TimeInterval) { elapsed = max(0, min(track.duration, time)); elapsedAt = Date(); push() }
    func setRate(_ value: Double) { freeze(); rate = value; push() }
    func toggleShuffle() { shuffle.toggle(); push() }
    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3; push() }
    func setLiked(_ on: Bool) { liked = on; push() }

    private func push() {
        guard active else { return }
        var s = NowPlayingSnapshot()
        let t = track
        s.title = t.title
        s.artist = t.artist
        s.album = t.album
        s.artwork = Self.artwork(t)
        s.artworkID = "sim-\(t.title)"
        s.duration = t.duration
        s.elapsed = elapsed
        s.timestamp = elapsedAt
        s.rate = rate
        s.isPlaying = playing
        s.shuffle = shuffle
        s.repeatMode = repeatMode
        s.bundleID = "com.apple.Music"
        s.explicit = index == 1
        s.link = URL(string: "https://open.spotify.com/track/simulated\(index)")
        s.canLike = true
        s.liked = liked
        s.audioFormat = ["Lossless", nil, "Dolby Atmos"][index]
        MediaController.shared.apply(s)
    }

    /// A self-contained NowPlayingState for offscreen gallery shots.
    static func sampleState(index: Int, playing: Bool) -> NowPlayingState {
        let t = tracks[index]
        let s = NowPlayingState()
        s.title = t.title
        s.artist = t.artist
        s.album = t.album
        s.artwork = artwork(t)
        s.colors = s.artwork.map(ArtworkColors.dominant) ?? s.colors
        s.isPlaying = playing
        s.duration = t.duration
        s.elapsed = t.duration * 0.37
        s.elapsedAt = Date()
        s.isExplicit = index == 1
        s.sourceBundleID = "com.apple.Music"
        return s
    }

    private static var artworkCache: [String: NSImage] = [:]

    /// Generated cover: gradient sky, a low sun and two hill lines.
    static func artwork(_ t: Track) -> NSImage {
        if let cached = artworkCache[t.title] { return cached }
        let size = NSSize(width: 240, height: 240)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: t.top, ending: t.bottom)?.draw(in: rect, angle: -90)
            let sun = NSBezierPath(ovalIn: NSRect(x: 70, y: 74, width: 100, height: 100))
            NSColor(white: 1, alpha: 0.55).setFill()
            sun.fill()
            for (i, alpha) in [(0, 0.55), (1, 0.85)] {
                let hill = NSBezierPath()
                let base = CGFloat(i) * 34 + 40
                hill.move(to: NSPoint(x: 0, y: base + 30))
                hill.curve(to: NSPoint(x: 240, y: base + 14), controlPoint1: NSPoint(x: 80, y: base + 70), controlPoint2: NSPoint(x: 150, y: base - 20))
                hill.line(to: NSPoint(x: 240, y: 0))
                hill.line(to: NSPoint(x: 0, y: 0))
                hill.close()
                t.bottom.blended(withFraction: 0.35 - CGFloat(i) * 0.3, of: .black)?.withAlphaComponent(alpha).setFill()
                hill.fill()
            }
            _ = rect
            return true
        }
        artworkCache[t.title] = image
        return image
    }
}

// MARK: - Artwork colours

enum ArtworkColors {
    /// Average colour of the top and bottom halves, lifted so it reads on black.
    static func dominant(_ image: NSImage) -> [NSColor] {
        let fallback = [NSColor(srgbRed: 0.83, green: 0.62, blue: 0.63, alpha: 1), NSColor(srgbRed: 0.42, green: 0.35, blue: 0.42, alpha: 1)]
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        let w = 4, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return fallback }
        // Bitmap memory starts with the top row.
        func average(rows: Range<Int>) -> NSColor {
            var r = 0.0, g = 0.0, b = 0.0
            for y in rows { for x in 0..<w { let i = (y * w + x) * 4; r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]) } }
            let n = Double(rows.count * w) * 255
            return NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
        }
        return [lift(average(rows: 0..<2), minBrightness: 0.62), lift(average(rows: 2..<4), minBrightness: 0.36)]
    }

    /// One colour standing for the artwork: its two halves mixed.
    static func mixed(_ colors: [NSColor]) -> NSColor {
        guard let first = colors.first else { return .white }
        return colors.count > 1 ? first.blended(withFraction: 0.5, of: colors[1]) ?? first : first
    }

    /// Saturated and bright, for the Colored style; a grey stays grey (its hue means nothing).
    static func vivid(_ color: NSColor) -> NSColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return NSColor(hue: hue, saturation: sat < 0.08 ? sat : min(1, max(0.6, sat * 1.4)), brightness: max(bri, 0.92), alpha: 1)
    }

    private static func lift(_ color: NSColor, minBrightness: CGFloat) -> NSColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(1, sat * 1.15), brightness: max(bri, minBrightness), alpha: 1)
    }
}

// MARK: - Title extras

enum TitleCleaner {
    private static let patterns = [
        #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#,
        #"\s*\[[^\]]*\]"#,
        #"\s*\((?:\d{4}\s+)?remaster(?:ed)?[^\)]*\)"#,
        #"\s+-\s+(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?(?:\s+version)?\s*$"#,
    ]

    /// "Song (feat. X) - Remastered 2011 [Live]" → "Song".
    static func clean(_ title: String) -> String {
        var t = title
        for p in patterns { t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    static func selfCheck() {
        let cases = [
            ("Palm Lines (feat. Mira) - Remastered 2024", "Palm Lines"),
            ("Song (Extended Mix) - 2011 Remaster", "Song (Extended Mix)"),
            ("Track [Live at Wembley]", "Track"),
            ("Title (Remastered 2009)", "Title"),
            ("Plain Title", "Plain Title"),
            ("Duet (with Someone)", "Duet"),
        ]
        for (input, expected) in cases {
            precondition(clean(input) == expected, "TitleCleaner: \(input) → \(clean(input))")
        }
    }
}
