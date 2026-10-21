import AppKit
import CryptoKit
import Network
import Security

/// What Spotify's Web API says about the playing item: the like, the explicit flag, three-way
/// repeat and episodes, none of which its AppleScript or MediaRemote carry reliably.
struct SpotifyPlayback: Equatable {
    var uri = ""
    var name = ""
    /// The artists, or the show for an episode.
    var artist = ""
    var episode = false
    var explicit = false
    /// "off", "context" or "track".
    var repeatState = "off"
    /// In the user's library; nil until asked.
    var liked: Bool?

    /// A GET /me/player body (currently-playing has the same shape); nil when nothing plays (an ad has no item).
    init?(json: Data) {
        struct Named: Decodable { var name: String }
        struct Item: Decodable { var uri: String?; var name: String?; var explicit: Bool?; var artists: [Named]?; var show: Named? }
        struct Body: Decodable { var repeat_state: String?; var currently_playing_type: String?; var item: Item? }
        guard let body = try? JSONDecoder().decode(Body.self, from: json), let item = body.item, let uri = item.uri else { return nil }
        self.uri = uri
        name = item.name ?? ""
        episode = body.currently_playing_type == "episode"
        artist = episode ? item.show?.name ?? "" : (item.artists ?? []).map(\.name).joined(separator: ", ")
        explicit = item.explicit ?? false
        repeatState = body.repeat_state ?? "off"
    }

    /// The open.spotify.com page; tracks and episodes have one (and can be liked), local files don't.
    var link: URL? { NowPlayingExtras.spotifyLink(uri) }
    var repeatMode: Int { repeatState == "track" ? 1 : repeatState == "context" ? 2 : 0 }

    /// Off → context → track (repeat one) → off.
    static func nextRepeat(after mode: Int) -> String { mode == 0 ? "context" : mode == 2 ? "track" : "off" }

    /// About the item the source shows, not the one before it.
    func matches(_ s: NowPlayingSnapshot) -> Bool {
        s.bundleID == SpotifyWeb.bundleID && (s.title.isEmpty || s.title.caseInsensitiveCompare(name) == .orderedSame)
    }

    func apply(to s: inout NowPlayingSnapshot) {
        s.explicit = explicit
        s.repeatMode = repeatMode
        s.episode = episode
        if s.title.isEmpty { s.title = name }
        if s.artist.isEmpty { s.artist = artist }
        guard let link else { return }
        s.link = link
        s.canLike = true
        s.liked = liked ?? s.liked
    }
}

/// Spotify's Web API through the user's own developer app (Isola has no registered one): Authorization
/// Code with PKCE in the browser, back to a loopback listener; the refresh token lives in the login
/// keychain, which nothing reads before the user connects. Polls only while Spotify is the source and plays.
///
/// Spotify's docs, as of October 2026:
/// - PKCE (S256; the token request sends client_id and code_verifier, no secret):
///   https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
/// - Redirect URIs (since April 2025: HTTP only for an explicit loopback literal such as 127.0.0.1; `localhost` is refused):
///   https://developer.spotify.com/documentation/web-api/concepts/redirect_uri
/// - Refreshing (client_id, no secret; a new refresh token may or may not come back):
///   https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens
/// - Playback state, with repeat_state and currently_playing_type (currently-playing omits repeat_state in practice):
///   https://developer.spotify.com/documentation/web-api/reference/get-information-about-the-users-current-playback
/// - Library: PUT/DELETE /me/library and GET /me/library/contains, which replaced /me/tracks and /me/episodes
///   for Development Mode apps: https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide
/// - Repeat, Premium only: https://developer.spotify.com/documentation/web-api/reference/set-repeat-mode-on-users-playback
/// The player endpoints have no playback speed.
@MainActor @Observable
final class SpotifyWeb {
    static let shared = SpotifyWeb()
    nonisolated static let bundleID = "com.spotify.client"
    nonisolated static let port: UInt16 = 47613
    nonisolated static let redirectURI = "http://127.0.0.1:\(port)/callback"
    nonisolated static let scopes = "user-read-playback-state user-modify-playback-state user-library-read user-library-modify"

    var clientID = UserDefaults.standard.string(forKey: "media.spotifyClientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID, forKey: "media.spotifyClientID") }
    }
    /// A refresh token is in the keychain (kept here so the keychain is never read before that).
    private(set) var connected = UserDefaults.standard.bool(forKey: "media.spotifyConnected") {
        didSet { UserDefaults.standard.set(connected, forKey: "media.spotifyConnected") }
    }
    private(set) var waiting = false
    private(set) var message: String?

    var status: String { message ?? (waiting ? "Waiting for Spotify in your browser…" : connected ? "Connected" : "Not connected") }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var renewing: Task<String?, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var followed = ""
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private var lastCommand = Date.distantPast
    /// The last reading, and the same while it is about the item the island shows.
    @ObservationIgnored private var now: SpotifyPlayback?
    @ObservationIgnored private var shown: SpotifyPlayback?

    // MARK: Connecting

    /// Settings › Connect: opens Spotify's consent page once the listener is up.
    func connect() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(id.isEmpty ? "Paste your app's Client ID first." : nil)
        guard !id.isEmpty else { return }
        clientID = id
        let verifier = Self.random(64), state = Self.random(16)
        let params = NWParameters.tcp
        // Loopback only: nothing off this Mac reaches it.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(integerLiteral: Self.port))
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return finish("Couldn't listen on port \(Self.port).") }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { SpotifyWeb.shared.answer(connection, state: state, verifier: verifier, clientID: id) }
        }
        listener.stateUpdateHandler = { update in
            MainActor.assumeIsolated {
                switch update {
                case .ready: NSWorkspace.shared.open(SpotifyWeb.authorizeURL(clientID: id, challenge: SpotifyWeb.challenge(verifier), state: state))
                case .failed(let error): SpotifyWeb.shared.finish("Couldn't listen on port \(SpotifyWeb.port): \(error)")
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        waiting = true
        // Don't hold the port for a sign-in that never comes back.
        Task {
            try? await Task.sleep(for: .seconds(300))
            if self.listener === listener { finish("Timed out waiting for Spotify.") }
        }
    }

    /// Settings › Disconnect: forgets the refresh token too.
    func disconnect() {
        drop(nil)
        Task.detached { SpotifyWeb.store(nil) }
    }

    /// Back to "not connected". The keychain item stays (Connect replaces it), so nothing asks for it again.
    private func drop(_ message: String?) {
        connected = false
        refreshToken = nil
        accessToken = nil
        now = nil
        shown = nil
        timer?.invalidate()
        timer = nil
        finish(message)
        NowPlayingSources.shared.redeliver()
    }

    /// Ends a sign-in attempt; no message means it went well (or there is nothing to say).
    private func finish(_ message: String?) {
        listener?.cancel()
        listener = nil
        waiting = false
        self.message = message
    }

    /// A request to the listener; Spotify's redirect carries the code (or an error) and our state.
    private func answer(_ connection: NWConnection, state: String, verifier: String, clientID: String) {
        connection.start(queue: .main)
        // ponytail: one read; a browser's GET arrives whole on loopback. Accumulate if a request line ever splits.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            MainActor.assumeIsolated {
                let line = String(decoding: data ?? Data(), as: UTF8.self).prefix { $0 != "\r" && $0 != "\n" }
                guard let query = SpotifyWeb.callbackQuery(String(line)) else { return SpotifyWeb.respond(connection, "404 Not Found", "Not found.") }
                // A stale tab or another page knocking: not ours, keep waiting.
                guard query["state"] == state else { return SpotifyWeb.respond(connection, "400 Bad Request", "This sign-in is out of date. Connect again from Isola's settings.") }
                let web = SpotifyWeb.shared
                guard let code = query["code"] else {
                    SpotifyWeb.respond(connection, "200 OK", "Isola isn't connected to Spotify. You can close this tab.")
                    return web.finish("Spotify said: \(query["error"] ?? "no code").")
                }
                SpotifyWeb.respond(connection, "200 OK", "Back to Isola. You can close this tab.")
                web.listener?.cancel()
                web.listener = nil
                web.exchange(code, verifier: verifier, clientID: clientID)
            }
        }
    }

    private nonisolated static func respond(_ connection: NWConnection, _ status: String, _ text: String) {
        let page = "<!doctype html><meta charset=utf-8><title>Isola</title><body style=\"font:15px -apple-system,sans-serif;margin:4em;text-align:center\"><p>\(text)</p>"
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + page).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct Token: Decodable { var access_token: String; var expires_in: Double; var refresh_token: String? }

    private func exchange(_ code: String, verifier: String, clientID: String) {
        Task {
            let reply = await Self.send(Self.tokenRequest([
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", Self.redirectURI),
                ("client_id", clientID), ("code_verifier", verifier),
            ]))
            guard reply?.status == 200, let token = reply.flatMap({ try? JSONDecoder().decode(Token.self, from: $0.body) }),
                  let refresh = token.refresh_token else {
                return finish(reply == nil ? "Couldn't reach Spotify." : "Spotify refused the sign-in: check the Client ID and the redirect URI.")
            }
            await Task.detached { SpotifyWeb.store(refresh) }.value
            refreshToken = refresh
            keep(token)
            connected = true
            finish(nil)
            NowPlayingSources.shared.poll()
        }
    }

    // MARK: Tokens

    private func keep(_ token: Token) {
        accessToken = token.access_token
        expiry = Date().addingTimeInterval(token.expires_in - 60)
    }

    /// A live access token. One renewal at a time: Spotify may rotate the refresh token, and a second
    /// request with the old one would fail.
    private func token() async -> String? {
        if let accessToken, Date() < expiry { return accessToken }
        if let renewing { return await renewing.value }
        let task = Task { await renew() }
        renewing = task
        let token = await task.value
        renewing = nil
        return token
    }

    private func renew() async -> String? {
        guard connected else { return nil }
        if refreshToken == nil { refreshToken = await Task.detached { SpotifyWeb.storedToken() }.value }
        guard let refresh = refreshToken else {
            // Gone, or the keychain said no: stop here rather than ask again every poll.
            drop("Isola couldn't read its Spotify sign-in from the keychain; connect again.")
            return nil
        }
        guard let reply = await Self.send(Self.tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", clientID)])) else { return nil }
        guard reply.status == 200, let token = try? JSONDecoder().decode(Token.self, from: reply.body) else {
            // invalid_grant: access revoked at spotify.com/account/apps, or the app deleted.
            if reply.status == 400 || reply.status == 401 { drop("Spotify access ended; connect again.") }
            return nil
        }
        keep(token)
        if let rotated = token.refresh_token, rotated != refresh {
            refreshToken = rotated
            await Task.detached { SpotifyWeb.store(rotated) }.value
        }
        return token.access_token
    }

    private nonisolated static func tokenRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(fields).utf8)
        return request
    }

    private nonisolated static func send(_ request: URLRequest) async -> (status: Int, body: Data)? {
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    /// One Web API request with a live token; nil without a token or a network.
    private func call(_ method: String, _ path: String, _ query: [(String, String)]) async -> (status: Int, body: Data)? {
        guard let token = await token() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1\(path)?\(Self.form(query))")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" { request.httpBody = Data() }  // Content-Length: 0
        let reply = await Self.send(request)
        if reply?.status == 401 { accessToken = nil }
        // ponytail: a flat 30 s pause when rate limited; read Retry-After if Spotify ever asks for longer.
        if reply?.status == 429 { quietUntil = Date().addingTimeInterval(30) }
        return reply
    }

    // MARK: Following the player

    /// Polls every 5 s while Spotify is the source and plays (at once, and 1.5 s into a new track since
    /// the Web API trails the app); never otherwise.
    func follow(_ snapshot: NowPlayingSnapshot?) {
        guard connected, let s = snapshot, s.bundleID == Self.bundleID, s.isPlaying else {
            timer?.invalidate()
            timer = nil
            return
        }
        let key = s.title + "\u{1f}" + s.artist
        guard timer == nil || key != followed else { return }
        followed = key
        timer?.invalidate()
        let t = Timer(fire: Date().addingTimeInterval(1.5), interval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { SpotifyWeb.shared.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// Reads playback (item, type, repeat), then whether the item is in the library. Skipped for 2 s
    /// after a command, and dropped if one goes out meanwhile: Spotify applies player commands
    /// asynchronously, and a stale reading would undo what the island already shows.
    private func refresh() {
        let started = Date()
        guard connected, !polling, started > quietUntil, started.timeIntervalSince(lastCommand) > 2 else { return }
        polling = true
        Task {
            defer { polling = false }
            guard let reply = await call("GET", "/me/player", [("additional_types", "episode")]), [200, 204].contains(reply.status) else { return }
            var playback = SpotifyPlayback(json: reply.body)
            if let uri = playback?.uri, playback?.link != nil,
               let saved = await call("GET", "/me/library/contains", [("uris", uri)]), saved.status == 200 {
                playback?.liked = (try? JSONDecoder().decode([Bool].self, from: saved.body))?.first
            }
            guard lastCommand < started else { return }
            if playback?.uri == now?.uri, playback?.liked == nil { playback?.liked = now?.liked }
            now = playback
            NowPlayingSources.shared.redeliver()
        }
    }

    /// Lays the reading over the source's snapshot when both are about the same item.
    func merge(into s: inout NowPlayingSnapshot) {
        shown = connected ? now.flatMap { $0.matches(s) ? $0 : nil } : nil
        shown?.apply(to: &s)
    }

    /// The item on show, unless the simulated player has the island.
    private var target: SpotifyPlayback? {
        if case .simulated = NowPlayingSources.shared.source { return nil }
        return shown
    }

    /// Shows a command's effect at once (or takes it back); polls stay out of its way.
    private func update(_ uri: String, _ change: (inout SpotifyPlayback) -> Void) {
        lastCommand = Date()
        guard var playback = now, playback.uri == uri else { return }
        change(&playback)
        now = playback
        NowPlayingSources.shared.redeliver()
    }

    // MARK: Commands

    /// Saves or removes the item in the library; false when the Web API doesn't cover it.
    func like(_ want: Bool) -> Bool {
        guard let item = target, item.link != nil else { return false }
        update(item.uri) { $0.liked = want }
        Task {
            let reply = await call(want ? "PUT" : "DELETE", "/me/library", [("uris", item.uri)])
            guard !(200..<300).contains(reply?.status ?? 0) else { return }
            update(item.uri) { $0.liked = item.liked }
            MediaUI.shared.show(notice: Self.problem(reply))
        }
        return true
    }

    /// Repeat off → context → track through the player endpoint. Refused (Premium only), the source's
    /// own repeat runs instead. False when the Web API doesn't cover the item.
    func cycleRepeat(fallback: @escaping () -> Void) -> Bool {
        guard let item = target else { return false }
        let next = SpotifyPlayback.nextRepeat(after: item.repeatMode)
        update(item.uri) { $0.repeatState = next }
        Task {
            let reply = await call("PUT", "/me/player/repeat", [("state", next)])
            guard !(200..<300).contains(reply?.status ?? 0) else { return }
            update(item.uri) { $0.repeatState = item.repeatState }
            MediaUI.shared.show(notice: Self.problem(reply))
            fallback()
        }
        return true
    }

    /// One line for a refused command, Premium spelled out.
    nonisolated static func problem(_ reply: (status: Int, body: Data)?) -> String {
        guard let reply else { return "Couldn't reach Spotify" }
        let error = ((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any])?["error"] as? [String: Any]
        if reply.status == 403, error?["reason"] as? String == "PREMIUM_REQUIRED" { return "Spotify Premium is needed to control playback" }
        return "Spotify: \(error?["message"] as? String ?? "error \(reply.status)")"
    }

    /// `isolactl media.state`.
    var summary: String {
        guard connected else { return waiting ? "waiting" : "off" }
        guard let shown else { return "connected" }
        return "\(shown.episode ? "episode" : "track"),repeat:\(shown.repeatState),liked:\(shown.liked.map(String.init) ?? "-"),explicit:\(shown.explicit)"
    }

    // MARK: Keychain (login keychain, a generic password owned by Isola)

    private nonisolated static func keychainItem() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.isola.mac.spotify", kSecAttrAccount as String: "refresh-token"]
    }

    private nonisolated static func storedToken() -> String? {
        var query = keychainItem()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored refresh token; nil deletes it.
    private nonisolated static func store(_ token: String?) {
        SecItemDelete(keychainItem() as CFDictionary)
        guard let token else { return }
        var item = keychainItem()
        item[kSecAttrLabel as String] = "Isola – Spotify"
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    // MARK: Pure parts

    /// RFC 7636 S256: unpadded base64url of the verifier's SHA-256.
    nonisolated static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Unreserved characters from the system's cryptographically secure generator.
    nonisolated static func random(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    nonisolated static func authorizeURL(clientID: String, challenge: String, state: String) -> URL {
        URL(string: "https://accounts.spotify.com/authorize?" + form([
            ("client_id", clientID), ("response_type", "code"), ("redirect_uri", redirectURI),
            ("code_challenge_method", "S256"), ("code_challenge", challenge), ("state", state), ("scope", scopes),
        ]))!
    }

    /// Form and query encoding: everything but unreserved characters escaped.
    nonisolated static func form(_ fields: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }.joined(separator: "&")
    }

    /// "GET /callback?code=…&state=… HTTP/1.1" → its query; nil for any other request (a favicon…).
    nonisolated static func callbackQuery(_ requestLine: String) -> [String: String]? {
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", let url = URLComponents(string: "http://127.0.0.1\(parts[1])"), url.path == "/callback" else { return nil }
        return Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    static func selfCheck() {
        // RFC 7636, appendix B.
        precondition(challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE S256")
        let verifier = random(64)
        precondition(verifier.count == 64 && verifier != random(64) && verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }, "verifier")

        let url = URLComponents(url: authorizeURL(clientID: "0f1e2d3c", challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", state: "s1"), resolvingAgainstBaseURL: false)
        let items = Dictionary(uniqueKeysWithValues: (url?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        precondition(url?.scheme == "https" && url?.host == "accounts.spotify.com" && url?.path == "/authorize" && items == [
            "client_id": "0f1e2d3c", "response_type": "code", "redirect_uri": "http://127.0.0.1:47613/callback", "code_challenge_method": "S256",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "state": "s1",
            "scope": "user-read-playback-state user-modify-playback-state user-library-read user-library-modify",
        ], "authorize URL: \(url?.string ?? "-")")
        precondition(form([("redirect_uri", redirectURI), ("scope", "a b")]) == "redirect_uri=http%3A%2F%2F127.0.0.1%3A47613%2Fcallback&scope=a%20b", "form encoding")
        precondition(callbackQuery("GET /callback?code=AQB_x-1&state=s1 HTTP/1.1") == ["code": "AQB_x-1", "state": "s1"], "callback")
        precondition(callbackQuery("GET /callback?error=access_denied&state=s1 HTTP/1.1")?["error"] == "access_denied", "denied")
        precondition(callbackQuery("GET /favicon.ico HTTP/1.1") == nil && callbackQuery("") == nil, "other requests")

        let track = SpotifyPlayback(json: Data(#"""
        {"device":{"id":"d1","is_active":true,"name":"MacBook Pro","type":"Computer"},"repeat_state":"track","shuffle_state":false,
         "timestamp":1761040000000,"progress_ms":42000,"is_playing":true,"currently_playing_type":"track",
         "item":{"type":"track","id":"4uLU6hMCjMI75M1A2tKUQC","uri":"spotify:track:4uLU6hMCjMI75M1A2tKUQC","name":"Velvet Static","explicit":true,
                 "duration_ms":187000,"artists":[{"name":"Oro Hills"},{"name":"Mira"}],"album":{"name":"Satellite Summer","images":[]},
                 "external_urls":{"spotify":"https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"}},
         "actions":{"disallows":{"resuming":true}}}
        """#.utf8))
        precondition(track?.explicit == true && track?.episode == false && track?.repeatMode == 1 && track?.artist == "Oro Hills, Mira", "track")
        precondition(track?.link?.absoluteString == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", "track link")
        let episode = SpotifyPlayback(json: Data(#"""
        {"repeat_state":"context","is_playing":true,"currently_playing_type":"episode","progress_ms":5000,
         "item":{"type":"episode","id":"512ojhOuo1ktJprKbVcKyQ","uri":"spotify:episode:512ojhOuo1ktJprKbVcKyQ","name":"Tides, Part 2","explicit":false,
                 "duration_ms":3600000,"show":{"name":"Harbour Radio"},"images":[]}}
        """#.utf8))
        precondition(episode?.episode == true && episode?.explicit == false && episode?.artist == "Harbour Radio" && episode?.repeatMode == 2, "episode")
        precondition(SpotifyPlayback(json: Data(#"{"is_playing":true,"currently_playing_type":"ad","item":null}"#.utf8)) == nil && SpotifyPlayback(json: Data()) == nil, "an ad, or 204")

        // Laid over the source's snapshot only for the same item.
        var s = NowPlayingSnapshot()
        (s.bundleID, s.title) = (bundleID, "tides, part 2")
        if let episode, episode.matches(s) { episode.apply(to: &s) }
        precondition(s.episode && s.artist == "Harbour Radio" && s.repeatMode == 2 && s.canLike, "episode merge")
        precondition(s.link?.absoluteString == "https://open.spotify.com/episode/512ojhOuo1ktJprKbVcKyQ", "episode link")
        precondition(track?.matches(s) == false, "a stale reading stays out")
        s.bundleID = "com.apple.Music"
        precondition(episode?.matches(s) == false, "another app's track")

        // Off (0) → context (all, 2) → track (one, 1) → off.
        let next = SpotifyPlayback.nextRepeat
        precondition(next(0) == "context" && next(2) == "track" && next(1) == "off", "repeat cycle")
        let premium = Data(#"{"error":{"status":403,"message":"Player command failed: Premium required","reason":"PREMIUM_REQUIRED"}}"#.utf8)
        precondition(problem((403, premium)) == "Spotify Premium is needed to control playback" && problem(nil) == "Couldn't reach Spotify", "refusals")
    }
}
