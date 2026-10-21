import AppKit
import CryptoKit
import IOKit
import Observation
import SwiftUI

struct LicensedMac: Identifiable, Codable, Equatable {
    /// This Mac's own id, or the licence server's opaque handle for another Mac (what deactivate takes).
    var id: String
    var name: String
    var model: String
    var activated: Date
}

/// Trial + licence state. Keys are checked here (format + checksum), then registered with the
/// website's licence server (api/license.ts), which keeps each key's Macs, up to three. Only a
/// definite answer changes the licence: 403 (this Mac isn't on the key) or 404 (no such key) takes
/// it away, 409 turns a fourth Mac down. Anything else (no connection, a throttle, a 5xx, a
/// checkpoint page, a body that doesn't decode) keeps what this Mac has.
@MainActor @Observable
final class License {
    static let shared = License()
    static let trialLength: TimeInterval = 72 * 3600
    static let deviceLimit = 3
    static let website = URL(string: "https://isola-ruby.vercel.app")!
    /// The licence server: <api>/activate, <api>/devices and <api>/deactivate.
    static let api = website.appendingPathComponent("api/license")
    /// Shared key the website hands out when its licence server can't be reached (/purchased/demo).
    static let demoKey = "ISOLA-DEMO-7Q4K-2M9X"
    static let unreachable = "Couldn’t reach the license server. Please try again later."
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private(set) var key: String?
    private(set) var devices: [LicensedMac]
    /// The server has this Mac on `key`: false until it says so, e.g. after this Mac's id changed.
    private(set) var registered: Bool
    /// What the licence server last said: "none" (not asked yet), "ok", "refused", "full",
    /// "offline" (no answer) or "offline-<status>" (an answer that is no verdict).
    private(set) var serverStatus = "none"
    private(set) var firstLaunch: Date
    /// Ticks once a minute so the trial countdown stays current.
    private(set) var now = Date()
    var draft = ""
    var message: String?

    enum Status: Equatable {
        case trial(remaining: TimeInterval)
        case expired
        case licensed
    }

    var trialEnds: Date { firstLaunch.addingTimeInterval(Self.trialLength) }

    var status: Status {
        if key != nil { return .licensed }
        let remaining = trialEnds.timeIntervalSince(now)
        return remaining > 0 ? .trial(remaining: remaining) : .expired
    }

    let thisMac: LicensedMac

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastReminder = Date.distantPast
    /// Gallery snapshots never talk to the server.
    @ObservationIgnored private var previewing = false
    /// Bumped by every request and every local change: the answer to an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var syncing = false
    /// Deactivations the server hasn't confirmed: this Mac, deactivated while the server couldn't
    /// be reached, or an id this Mac no longer goes by. Retried at every sync until it answers.
    @ObservationIgnored private var pending: [Pending]
    private let store: UserDefaults

    struct Pending: Codable, Equatable {
        var key: String
        var id: String
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        let key = store.string(forKey: "license.key")
        var registered = store.bool(forKey: "license.registered")
        var pending = store.data(forKey: "license.pending").flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
        let stored = store.string(forKey: "license.deviceID"), hardware = Self.hardwareID()
        let (id, retired) = Self.deviceID(stored: stored, storedHardware: store.string(forKey: "license.deviceHardware"), hardware: hardware)
        if let key, id != stored {
            // The server knows this Mac by another id, or not at all: register it again, once the
            // old id, if it was this Mac's own, is off the key.
            registered = false
            if let retired, key != Self.demoKey, !pending.contains(Pending(key: key, id: retired)) {
                pending.append(Pending(key: key, id: retired))
            }
        }
        self.key = key
        self.registered = registered
        self.pending = pending
        devices = (store.data(forKey: "license.devices")).flatMap { try? JSONDecoder().decode([LicensedMac].self, from: $0) } ?? []
        firstLaunch = store.object(forKey: "license.firstLaunch") as? Date ?? Date()
        thisMac = LicensedMac(id: id, name: Host.current().localizedName ?? "This Mac", model: Self.modelIdentifier(), activated: Date())
        store.set(id, forKey: "license.deviceID")
        store.set(hardware, forKey: "license.deviceHardware")
        save()
    }

    func start() {
        if store.object(forKey: "license.firstLaunch") == nil { store.set(firstLaunch, forKey: "license.firstLaunch") }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { License.shared.tick() }
        }
        tick()
        refresh()
    }

    private func tick() {
        now = Date()
        // Expired trials keep working, with a gentle reminder every few hours.
        guard status == .expired, now.timeIntervalSince(lastReminder) > 3 * 3600 else { return }
        lastReminder = now
        Island.shared.post(Self.reminder(), duration: 6)
    }

    static func reminder() -> IslandItem {
        IslandItem(id: "license.reminder", kind: .notification) {
            Image(systemName: "key.fill").islandSymbol(15).foregroundStyle(Palette.amber).padding(.leading, 12)
        } trailing: {
            Text("Trial ended").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted).padding(.trailing, 12)
        }
        .onTap { SettingsWindow.show(section: "license") }
    }

    // MARK: - Activation

    /// Checks the key here, then registers this Mac with the licence server. Nothing changes until
    /// the server says yes.
    func activate(_ raw: String) {
        let candidate = Self.normalize(raw)
        guard Self.isValid(candidate) else {
            message = "That doesn’t look like an Isola license key."
            return
        }
        message = nil
        // Activating again takes back a deactivation of this Mac that hasn't reached the server.
        drop(Pending(key: candidate, id: thisMac.id))
        Task { await register(candidate) }
    }

    /// Activation, and the sync of a Mac the server doesn't know yet.
    private func register(_ candidate: String) async {
        let device = ["id": thisMac.id, "name": thisMac.name, "model": thisMac.model]
        guard let reply = await ask("activate", ["key": candidate, "device": device]) else { return }
        let current = key == candidate
        switch reply {
        case .devices(let list):
            key = candidate
            devices = list
            registered = true
            draft = ""
            message = nil
            save()
        case .refused(let error):
            if current { revoke(error) } else { message = error }
        case .full(let error):
            message = error  // this Mac keeps whatever it had
        case .failed:
            // A sync that doesn't get through says so under the device list instead.
            if !current { message = Self.unreachable }
        }
    }

    /// A definite no for the key this Mac uses: back to the trial.
    private func revoke(_ error: String) {
        key = nil
        devices = []
        registered = false
        message = error
        generation += 1
        save()
    }

    /// Syncs with the server: at launch, and every time the License tab is shown. Pending
    /// deactivations go first; then a Mac the server doesn't know registers, and a registered one
    /// takes the server's list. Only a definite answer changes anything.
    func refresh() {
        guard !previewing, !syncing else { return }
        syncing = true
        Task {
            defer { syncing = false }
            await settlePending()
            guard let key else { return }
            if !registered { return await register(key) }
            // The shared demo key keeps no list on the server: it's just this Mac.
            guard key != Self.demoKey, let reply = await ask("devices", ["key": key, "deviceId": thisMac.id]) else { return }
            switch reply {
            case .devices(let list):
                devices = list
                save()
            case .refused(let error):
                revoke(error)
            case .full, .failed:
                break
            }
        }
    }

    /// This Mac goes at once, offline too, so nobody is stuck licensed; the server hears of it now,
    /// or at a later sync. Another Mac (`id` is the server's handle for it) needs the server, which
    /// lets a Mac remove only itself or a Mac activated after it.
    func deactivate(_ id: String) {
        guard let key else { return }
        if id == thisMac.id {
            if key != Self.demoKey, !pending.contains(Pending(key: key, id: id)) { pending.append(Pending(key: key, id: id)) }
            self.key = nil
            devices = []
            registered = false
            message = nil
            generation += 1
            save()
            Task { await settlePending() }
            return
        }
        Task {
            guard let reply = await ask("deactivate", ["key": key, "deviceId": thisMac.id, "target": id]) else { return }
            switch reply {
            case .devices(let list):
                devices = list
                message = nil
                save()
            case .refused(let error):
                // A Mac activated before this one, or this Mac is off the key: the sync tells which.
                message = error
                refresh()
            case .full, .failed:
                message = Self.unreachable
            }
        }
    }

    /// Retries the deactivations the server hasn't confirmed. A definite answer settles one (gone
    /// now, or not there to begin with); anything else keeps it for the next sync.
    private func settlePending() async {
        for item in pending {
            let body = Self.json(["key": item.key, "deviceId": item.id, "target": item.id])
            switch await Self.post(Self.api.appendingPathComponent("deactivate"), body) {
            case .devices, .refused: drop(item)
            case .full, .failed: break
            }
        }
    }

    private func drop(_ item: Pending) {
        guard pending.contains(item) else { return }
        pending.removeAll { $0 == item }
        save()
    }

    func reset() {
        key = nil
        devices = []
        registered = false
        serverStatus = "none"
        firstLaunch = Date()
        store.set(firstLaunch, forKey: "license.firstLaunch")
        message = nil
        generation += 1
        save()
        now = Date()
    }

    /// For gallery snapshots only.
    func preview(key: String?, devices: [LicensedMac], firstLaunch: Date, message: String? = nil, serverStatus: String = "ok") {
        previewing = true
        self.key = key
        self.devices = devices
        self.firstLaunch = firstLaunch
        self.message = message
        self.serverStatus = serverStatus
        now = Date()
    }

    private func save() {
        store.set(key, forKey: "license.key")
        store.set(try? JSONEncoder().encode(devices), forKey: "license.devices")
        store.set(registered, forKey: "license.registered")
        store.set(try? JSONEncoder().encode(pending), forKey: "license.pending")
    }

    /// The key as isolactl shows it, since any process can listen in: ISOLA-****-****-8HUK.
    static func mask(_ key: String?) -> String {
        key.map { "ISOLA-****-****-" + $0.suffix(4) } ?? "none"
    }

    var pendingDeactivations: Int { pending.count }

    // MARK: - Licence server

    /// What a call to the licence server came to.
    enum Reply: Equatable {
        /// 2xx with the key's Macs: this one under its own id, the others under the server's handles.
        case devices([LicensedMac])
        /// 403 (this Mac isn't on the key) or 404 (no such key), with the server's sentence.
        case refused(String)
        /// 409: the key is on three Macs already.
        case full(String)
        /// Anything else, with the HTTP status if there was one: never a verdict.
        case failed(Int?)
    }

    /// The server's {devices} or {error}; its dates are ISO 8601 without fractional seconds.
    private struct Answer: Decodable {
        var devices: [LicensedMac]?
        var error: String?
    }

    /// Only the server's own JSON counts: a 2xx with its {devices}, or a 403, 404 or 409 with its
    /// {error}. A 2xx that doesn't decode, a Vercel checkpoint page, a throttle (503 or 429) or
    /// any other status is `.failed`, whatever its body says.
    nonisolated static func classify(status: Int?, body: Data) -> Reply {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let answer = try? decoder.decode(Answer.self, from: body)
        switch (status ?? 0, answer?.devices, answer?.error) {
        case (200..<300, let devices?, _): return .devices(devices)
        case (403, _, let error?), (404, _, let error?): return .refused(error)
        case (409, _, let error?): return .full(error)
        default: return .failed(status)
        }
    }

    /// POST <api>/<action> for the licence state, noted in `serverStatus`; nil when the answer is
    /// stale (a newer request or a local change came after it).
    private func ask(_ action: String, _ body: [String: Any]) async -> Reply? {
        generation += 1
        let asked = generation
        let reply = await Self.post(Self.api.appendingPathComponent(action), Self.json(body))
        guard asked == generation else { return nil }
        serverStatus = switch reply {
        case .devices: "ok"
        case .refused: "refused"
        case .full: "full"
        case .failed(let status): status.map { "offline-\($0)" } ?? "offline"
        }
        return reply
    }

    private static func json(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private nonisolated static func post(_ url: URL, _ body: Data) async -> Reply {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .failed(nil) }
        return classify(status: (response as? HTTPURLResponse)?.statusCode, body: data)
    }

    // MARK: - This Mac's id

    /// Which id this Mac goes by on the licence server: its hardware's, unless a stored id was made
    /// on this same hardware. Preferences copied from another Mac (Migration Assistant, a restored
    /// backup) bring that Mac's id and hardware hash, which don't match, so they give way. A stored id
    /// with no hardware hash predates them and was this Mac's: it comes back as `retired`, for the
    /// server to drop. No hardware id at all (never on a real Mac): the stored id stays, or a random
    /// one stands in.
    nonisolated static func deviceID(stored: String?, storedHardware: String?, hardware: String?) -> (id: String, retired: String?) {
        guard let hardware else { return (stored ?? UUID().uuidString, nil) }
        guard let stored, stored != hardware else { return (hardware, nil) }
        if storedHardware == hardware { return (stored, nil) }
        return (hardware, storedHardware == nil ? stored : nil)
    }

    /// SHA-256 of an IOPlatformUUID with this app's salt: the same in every account on the Mac, and
    /// unlike the UUID itself, no use to any other app.
    nonisolated static func hardwareHash(_ platformUUID: String) -> String {
        SHA256.hash(data: Data("app.isola.mac/license-device:\(platformUUID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// This Mac's hardware id; nil if IOKit can't say.
    private static func hardwareID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        return uuid.map(hardwareHash)
    }

    // MARK: - Key format: ISOLA-XXXX-XXXX-XXXX, last character is a weighted checksum.

    static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace }
    }

    static func isValid(_ key: String) -> Bool {
        if key == demoKey { return true }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "ISOLA", parts.dropFirst().allSatisfy({ $0.count == 4 && $0.allSatisfy(alphabet.contains) }) else {
            return false
        }
        let body = Array(parts.dropFirst().joined())
        return checksum(body.dropLast()) == body.last
    }

    static func checksum<S: Sequence>(_ chars: S) -> Character where S.Element == Character {
        let sum = chars.enumerated().reduce(0) { total, item in
            total + (alphabet.firstIndex(of: item.element) ?? 0) * (item.offset + 7)
        }
        return alphabet[sum % alphabet.count]
    }

    /// Deterministic valid key for demos (e.g. `license.set key=$(...)`).
    static func makeKey(seed: Int) -> String {
        var rng = seed
        let body: [Character] = (0..<11).map { _ in
            rng = (rng &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
            return alphabet[rng % alphabet.count]
        }
        let full = body + [checksum(body)]
        return "ISOLA-" + stride(from: 0, to: 12, by: 4).map { String(full[$0..<$0 + 4]) }.joined(separator: "-")
    }

    static func selfCheck() {
        let key = makeKey(seed: 42)
        precondition(isValid(key), "generated key must validate")
        var tampered = Array(key)
        tampered[6] = tampered[6] == "A" ? "B" : "A"
        precondition(!isValid(String(tampered)), "a changed character must fail the checksum")
        precondition(isValid(demoKey), "the website demo key is accepted")
        precondition(!isValid("ISOLA-ABCD-EFGH"), "too short")
        precondition(isValid(normalize(" isola" + key.dropFirst(5).lowercased() + " ")), "case and spaces are forgiven")
        // What the licence server (api/license.ts) mints.
        precondition(isValid("ISOLA-U9VJ-DMME-DWJU"), "a key minted by the licence server validates")
        precondition(mask("ISOLA-W7UD-A389-NXLG") == "ISOLA-****-****-NXLG" && mask(nil) == "none", "isolactl never shows a whole key")

        // Only the server's own JSON is a verdict; anything else keeps the licence as it is.
        let reply = { (status: Int?, body: String) in classify(status: status, body: Data(body.utf8)) }
        let list = #"{"devices":[{"id":"A","name":"Studio","model":"Mac14,13","activated":"2026-10-21T09:41:00Z"},{"id":"kQ3vX9_bR2mT7wYc1LpZ0a","name":"Air","model":"Mac15,12","activated":"2026-10-21T10:00:00Z"}]}"#
        guard case .devices(let macs) = reply(200, list), macs.map(\.name) == ["Studio", "Air"] else {
            preconditionFailure("a 2xx with {devices} is the list")
        }
        let notOnKey = #"{"error":"This Mac isn’t activated with that license."}"#
        let checkpoint = "<!DOCTYPE html><html><head><title>Vercel Security Checkpoint</title></head><body></body></html>"
        precondition(reply(403, notOnKey) == .refused("This Mac isn’t activated with that license."), "403 with the server's {error}: off the key")
        precondition(reply(404, #"{"error":"That license key doesn’t exist."}"#) == .refused("That license key doesn’t exist."), "404: no such key")
        precondition(reply(409, #"{"error":"This license is already active on 3 Macs. Deactivate one first."}"#)
            == .full("This license is already active on 3 Macs. Deactivate one first."), "409: the limit")
        precondition(reply(200, checkpoint) == .failed(200) && reply(200, "{}") == .failed(200) && reply(201, "") == .failed(201),
                     "a 2xx without the list is an error, not a success")
        precondition(reply(403, checkpoint) == .failed(403) && reply(429, checkpoint) == .failed(429), "a checkpoint page is no verdict")
        precondition(reply(404, "The page could not be found\n\nNOT_FOUND") == .failed(404), "nor is the platform's own 404")
        precondition(reply(403, #"{"error":{"code":"forbidden"}}"#) == .failed(403), "nor someone else's JSON")
        for status in [400, 415, 429, 500, 502, 503] {
            precondition(reply(status, notOnKey) == .failed(status), "\(status) is never a verdict, whatever it says")
        }
        precondition(reply(nil, "") == .failed(nil), "no answer at all")

        // This Mac's id: the hardware's, unless a stored one was made on the same hardware.
        let here = hardwareHash("6C1E6F5A-0D1B-4D9E-9C1A-2F4B8E7D3A10"), there = hardwareHash("0F7A2B44-91C3-4E6A-8B25-7D3E1C9A5F60")
        precondition(here.count == 64 && here != there && !here.contains("6C1E6F5A"), "a salted SHA-256, one per Mac")
        precondition(hardwareHash("00000000-0000-0000-0000-000000000000")
            == "10a2f3353f802bd66caf20f7a60c95285aac39553629ea6d46ec75977bf3fcb6", "SHA-256 of app.isola.mac/license-device:<IOPlatformUUID>")
        func id(_ stored: String?, _ storedHardware: String?, _ hardware: String?) -> (String, String?) {
            let result = deviceID(stored: stored, storedHardware: storedHardware, hardware: hardware)
            return (result.id, result.retired)
        }
        precondition(id(nil, nil, here) == (here, nil), "a new install takes the hardware's id")
        precondition(id(here, here, here) == (here, nil), "and keeps it")
        precondition(id("kept-id", here, here) == ("kept-id", nil), "a stored id made on this hardware stays")
        precondition(id(there, there, here) == (here, nil), "another Mac's id, copied over, gives way and is left alone")
        precondition(id("4F6C3B9E-UUID", nil, here) == (here, "4F6C3B9E-UUID"), "an id from before is retired for the server to drop")
        precondition(id("4F6C3B9E-UUID", nil, nil) == ("4F6C3B9E-UUID", nil), "no hardware id: the stored one stays")
        precondition(id(nil, nil, nil).0.count == 36, "or a random one stands in")
        precondition(hardwareID().map { $0.count == 64 } ?? true, "this Mac's own")
    }

    private static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

/// Once a day, the website's releases.json against this build: a newer release is
/// announced in the island (tap to download) unless the prompt is silenced.
@MainActor @Observable
final class Updates {
    static let shared = Updates()
    static let feed = URL(string: "https://isola-ruby.vercel.app/releases.json")!

    struct Release: Decodable {
        var version: String
        var build: Int?
        var url: URL
        var notes: String?
    }

    var silenced = UserDefaults.standard.bool(forKey: "updates.silenced") {
        didSet { UserDefaults.standard.set(silenced, forKey: "updates.silenced") }
    }
    private(set) var available: Release?
    private(set) var lastCheck = UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date
    private(set) var failed = false
    @ObservationIgnored private var timer: Timer?

    /// This build, e.g. ("1.4.7", 151); nil when running unbundled (gallery, swift run).
    static var current: (version: String, build: Int?)? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        return (version, (info?["CFBundleVersion"] as? String).flatMap { Int($0) })
    }

    func start() {
        guard Self.current != nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updates.shared.checkIfDue() }
        }
    }

    /// Failed checks aren't recorded, so the hourly timer retries them.
    private func checkIfDue() {
        if Date().timeIntervalSince(lastCheck ?? .distantPast) >= 24 * 3600 { check() }
    }

    func check() {
        URLSession.shared.dataTask(with: Self.feed) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let release = ok ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) } : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { Updates.shared.received(release) } }
        }.resume()
    }

    private func received(_ release: Release?) {
        failed = release == nil
        guard let release, let current = Self.current else { return }
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: "updates.lastCheck")
        available = Self.isNewer(release.version, build: release.build, than: current.version, build: current.build) ? release : nil
        if let available, !silenced { Island.shared.post(Self.prompt(available), duration: 8) }
    }

    /// Dotted versions compare numerically ("1.10" > "1.9", "1.4" == "1.4.0"); the same
    /// version is newer only with a higher build.
    nonisolated static func isNewer(_ version: String, build: Int?, than current: String, build currentBuild: Int?) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(a.count, b.count)
        let x = a + Array(repeating: 0, count: n - a.count), y = b + Array(repeating: 0, count: n - b.count)
        if x != y { return y.lexicographicallyPrecedes(x) }
        guard let build, let currentBuild else { return false }
        return build > currentBuild
    }

    static func prompt(_ release: Release) -> IslandItem {
        IslandItem(id: "updates.available", kind: .notification) {
            Image(systemName: "arrow.down.circle.fill").islandSymbol(16).foregroundStyle(Palette.green).padding(.leading, 12)
        } trailing: {
            WingText(release.version, color: Palette.green)
        }
        .peek(always: true) { PeekLabel("Isola \(release.version) is available") }
        .onTap {
            NSWorkspace.shared.open(release.url)
            Island.shared.dismissTransient()
        }
    }

    /// For gallery snapshots only.
    func preview(_ release: Release?, checked: Date?) {
        available = release
        lastCheck = checked
    }

    static let sample = Release(version: "1.5", build: 160, url: License.website.appendingPathComponent("download"), notes: "Lock Screen widgets and a faster island.")

    static func gallery() {
        precondition(isNewer("1.5", build: nil, than: "1.4.7", build: 151) && isNewer("1.4.10", build: nil, than: "1.4.9", build: nil), "newer version")
        precondition(isNewer("1.4.7", build: 152, than: "1.4.7", build: 151) && !isNewer("1.4.7", build: 151, than: "1.4.7", build: 151), "same version, by build")
        precondition(!isNewer("1.4", build: nil, than: "1.4.0", build: nil) && !isNewer("1.3.9", build: 999, than: "1.4", build: 1), "equal or older")
        let json = #"{"version":"1.4.7","build":151,"url":"https://isola-ruby.vercel.app/download","notes":"..."}"#
        precondition((try? JSONDecoder().decode(Release.self, from: Data(json.utf8)))?.build == 151, "releases.json shape")
        Gallery.island("update-available-pill", item: prompt(sample))
        Gallery.island("update-available-notch", item: prompt(sample), geometry: .notchPreview)
    }
}

/// Settings › License.
struct LicensePage: View {
    @Bindable var license = License.shared
    @Bindable var updates = Updates.shared

    var body: some View {
        Form {
            Section { status }
            switch license.status {
            case .licensed:
                Section {
                    // In activation order: a Mac can remove itself or a Mac activated after it.
                    let mine = license.devices.firstIndex { $0.id == license.thisMac.id }
                    ForEach(Array(license.devices.enumerated()), id: \.element.id) { index, mac in
                        deviceRow(mac, removable: mine.map { index >= $0 } ?? true)
                    }
                } header: {
                    Text("Activated Macs (\(license.devices.count) of \(License.deviceLimit))")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let message = license.message {
                            Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        }
                        Text("Deactivate a Mac to free a slot for another one. A Mac can remove itself or any Mac activated after it."
                            + (license.serverStatus.hasPrefix("offline") ? " Couldn’t reach the license server, so this list may be out of date." : ""))
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .trial, .expired:
                Section("Activate") {
                    LabeledContent("License key") {
                        TextField("License key", text: $license.draft, prompt: Text("ISOLA-XXXX-XXXX-XXXX"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .onSubmit { license.activate(license.draft) }
                    }
                    HStack {
                        if let message = license.message {
                            Label(message, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                        Spacer()
                        Button("Activate") { license.activate(license.draft) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(license.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            Section {
                Link(destination: License.website.appendingPathComponent("recover")) {
                    Label("Lost your license?", systemImage: "envelope")
                }
                if license.status != .licensed {
                    Link(destination: License.website) {
                        Label("Buy a license — $13.99, one-time", systemImage: "cart")
                    }
                }
            }
            Section {
                LabeledContent {
                    if let release = updates.available {
                        Link("Download", destination: release.url)
                    } else {
                        Button("Check Now") { updates.check() }
                    }
                } label: {
                    Text(updateTitle)
                    Text(updateDetail)
                }
                Toggle("Silence update prompt", isOn: $updates.silenced)
            } header: {
                Text("Updates")
            } footer: {
                Text("Isola checks once a day and shows a new version in the island. Silenced, it only appears here.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        // Every time the tab is shown: switching to it, and the Settings window opening on it or
        // coming back to the front.
        .onAppear { license.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === SettingsWindow.window { license.refresh() }
        }
    }

    private var updateTitle: String {
        if let release = updates.available { return "Isola \(release.version) is available" }
        if updates.failed { return "Couldn’t check for updates" }
        return updates.lastCheck == nil ? "Not checked yet" : "Isola is up to date"
    }

    /// Release notes when there's an update, else this build and when it was last checked.
    private var updateDetail: String {
        if let notes = updates.available?.notes { return notes }
        let build = Updates.current.map { "Version \($0.version)" + ($0.build.map { " (\($0))" } ?? "") } ?? "Development build"
        guard let checked = updates.lastCheck else { return build }
        return "\(build) · checked \(checked.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder private var status: some View {
        switch license.status {
        case .licensed:
            StatusRow(symbol: "checkmark.seal.fill", tint: .green, title: "Isola is licensed", detail: "Thanks for supporting Isola. All future updates are included.")
        case .trial(let remaining):
            VStack(alignment: .leading, spacing: 10) {
                StatusRow(symbol: "clock.fill", tint: .orange, title: "Free trial", detail: "\(Self.hours(remaining)) left of your 72-hour trial.")
                ProgressView(value: remaining, total: License.trialLength).tint(.orange)
            }
        case .expired:
            StatusRow(symbol: "exclamationmark.triangle.fill", tint: .red, title: "Your trial has ended", detail: "Isola keeps working, but please buy a license to support it.")
        }
    }

    private func deviceRow(_ mac: LicensedMac, removable: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: mac.model.hasPrefix("MacBook") ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mac.name).fontWeight(.medium)
                    if mac.id == license.thisMac.id {
                        Text("This Mac")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                Text("\(mac.model) · since \(mac.activated.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deactivate") { license.deactivate(mac.id) }
                .disabled(!removable)
                .help(removable ? "" : "Activated before this Mac: only that Mac, or one activated before it, can remove it.")
        }
    }

    static func hours(_ seconds: TimeInterval) -> String {
        let h = Int(seconds / 3600)
        return h >= 1 ? "\(h) hour\(h == 1 ? "" : "s")" : "\(max(1, Int(seconds / 60))) minutes"
    }
}

struct StatusRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
