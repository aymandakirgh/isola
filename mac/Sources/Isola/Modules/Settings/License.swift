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
    /// When the server last heard from it, to the day; nil from a server that doesn't say.
    var lastSeen: Date?

    /// The server lets any Mac on the key remove one it hasn't heard from in this long.
    static let staleAfter: TimeInterval = 30 * 24 * 3600

    func stale(at now: Date) -> Bool { now.timeIntervalSince(lastSeen ?? activated) > Self.staleAfter }
}

/// Trial + licence state. Keys are checked here (format + checksum), then registered with the
/// website's licence server (api/license.ts), which keeps each key's Macs, up to three. Only the
/// server's verdicts, told by their code, change the licence: not_on_key or unknown_key takes it
/// away, limit turns a fourth Mac down, order refuses to remove an earlier Mac. Anything else (no
/// connection, a throttle, a 5xx, an unknown route, a checkpoint page, a body that doesn't decode)
/// keeps what this Mac has.
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
    /// The server has this Mac on `key`: false until it says so, e.g. after preferences came over
    /// from another Mac.
    private(set) var registered: Bool
    /// What the licence server last said: "none" (not asked yet), "ok", "refused", "full", "order",
    /// "offline" (no answer) or "offline-<status>" (an answer that is no verdict).
    private(set) var serverStatus = "none"
    private(set) var firstLaunch: Date
    /// Ticks once a minute so the trial countdown stays current.
    private(set) var now = Date()
    var draft = ""
    var message: String?
    /// "Licensed to": a name or e-mail typed at activation. It stays in this Mac's preferences and
    /// is never sent to the licence server, which keeps no e-mail.
    private(set) var owner: String?
    var ownerDraft = ""

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
    @ObservationIgnored private var wasExpired = false
    /// Gallery snapshots never talk to the server.
    @ObservationIgnored private var previewing = false
    /// Bumped by every request and every local change: the answer to an older one is dropped.
    @ObservationIgnored private var generation = 0
    /// The pending deactivations being sent right now, so an activation can wait for them.
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var lastSync = Date.distantPast
    /// Deactivations of this Mac the server hasn't confirmed (deactivated while it couldn't be
    /// reached). Retried at every sync until it answers.
    @ObservationIgnored private var pending: [Pending]
    private let store: UserDefaults

    struct Pending: Codable, Equatable {
        var key: String
        var id: String
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        key = store.string(forKey: "license.key")
        let stored = store.string(forKey: "license.deviceID"), hardware = Self.hardwareID()
        let id = Self.deviceID(stored: stored, storedHardware: store.string(forKey: "license.deviceHardware"), hardware: hardware)
        // A new id (a first launch, or preferences copied from another Mac) isn't on the server: this
        // Mac registers under it, and deactivations queued under the old one stay with the Mac it's from.
        let newID = id != stored
        registered = !newID && store.bool(forKey: "license.registered")
        pending = newID ? [] : store.data(forKey: "license.pending").flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
        devices = (store.data(forKey: "license.devices")).flatMap { try? JSONDecoder().decode([LicensedMac].self, from: $0) } ?? []
        firstLaunch = store.object(forKey: "license.firstLaunch") as? Date ?? Date()
        let owner = store.string(forKey: "license.owner")
        self.owner = owner
        ownerDraft = owner ?? ""
        thisMac = LicensedMac(id: id, name: Host.current().localizedName ?? "This Mac", model: Self.modelIdentifier(), activated: Date())
        store.set(id, forKey: "license.deviceID")
        if let hardware { store.set(hardware, forKey: "license.deviceHardware") }
        save()
    }

    func start() {
        if store.object(forKey: "license.firstLaunch") == nil { store.set(firstLaunch, forKey: "license.firstLaunch") }
        Debug.on("license.trialExpired") { _ in TrialExpiredWindow.show() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { License.shared.tick() }
        }
        tick()
    }

    private func tick() {
        now = Date()
        // At launch, then once a day: a Mac that runs for weeks still tells the server it's in use,
        // which lets any Mac on the key remove one it hasn't heard from in 30 days.
        if now.timeIntervalSince(lastSync) >= 24 * 3600 { refresh() }
        // The trial ran out just now, or before this launch: the Trial Expired window, once a day at most.
        // It's this round's reminder: no island pill on top of it.
        let expired = status == .expired
        if expired, !wasExpired, TrialExpiredWindow.showIfDue() { lastReminder = now }
        wasExpired = expired
        // Expired trials keep working, with a gentle reminder every few hours.
        guard expired, now.timeIntervalSince(lastReminder) > 3 * 3600 else { return }
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
    /// the server says yes. `owner` is the License page's Name or e-mail: the forms without that
    /// field activate without one.
    func activate(_ raw: String, owner: String = "") {
        let candidate = Self.normalize(raw)
        guard Self.isValid(candidate) else {
            message = "That doesn’t look like an Isola license key."
            return
        }
        message = nil
        Task { await register(candidate, owner: owner) }
    }

    /// Activation, and the sync of a Mac the server doesn't have yet. Only an activation brings
    /// an owner (empty clears it); a sync leaves it as it is.
    private func register(_ candidate: String, owner: String? = nil) async {
        // A deactivation of this Mac already on its way would land after this activation and take
        // the Mac off the key again: let it finish first.
        await settling?.value
        let device = ["id": thisMac.id, "name": thisMac.name, "model": thisMac.model]
        guard let reply = await ask("activate", ["key": candidate, "device": device]) else { return }
        let current = key == candidate
        switch reply {
        case .devices(let list):
            // Only once the server says yes: this takes back a deactivation of this Mac still on its way.
            pending.removeAll { $0 == Pending(key: candidate, id: thisMac.id) }
            key = candidate
            devices = list
            registered = true
            if let owner {
                let name = owner.trimmingCharacters(in: .whitespacesAndNewlines)
                self.owner = name.isEmpty ? nil : name
            }
            draft = ""
            message = nil
            save()
        case .refused(let error), .full(let error):
            // No such key, or a full one without this Mac (the server always lists a Mac it has):
            // this Mac isn't on that licence, even holding its key (preferences from another Mac).
            if current { revoke(error) } else { message = error }
        case .order(let error):
            message = error
        case .failed:
            // A sync that doesn't get through says so under the device list instead.
            if !current { message = Self.unreachable }
        }
    }

    /// Back to the trial: a definite no for the key this Mac uses (`error` is the server's sentence),
    /// or this Mac deactivated. The name it was licensed to goes with the key.
    private func revoke(_ error: String?) {
        key = nil
        devices = []
        registered = false
        owner = nil
        ownerDraft = ""
        message = error
        generation += 1
        save()
    }

    /// Syncs with the server: at launch, once a day, and every time the License tab is shown.
    /// Pending deactivations go first; then a Mac the server doesn't have registers, and a
    /// registered one takes the server's list. Only a verdict changes anything.
    func refresh() {
        guard !previewing, !syncing else { return }
        syncing = true
        lastSync = Date()
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
            case .full, .order, .failed:
                break
            }
        }
    }

    /// This Mac goes at once, offline too, so nobody is stuck licensed; the server hears of it now,
    /// or at a later sync. Another Mac (`id` is the server's handle for it) needs the server, which
    /// lets a Mac remove itself, a Mac activated after it, or one not seen for 30 days.
    func deactivate(_ id: String) {
        guard let key else { return }
        if id == thisMac.id {
            if key != Self.demoKey, !pending.contains(Pending(key: key, id: id)) { pending.append(Pending(key: key, id: id)) }
            revoke(nil)
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
                revoke(error)  // this Mac is off the key itself
            case .order(let error), .full(let error):
                message = error
                refresh()  // the server has heard from that Mac lately: the list shows when
            case .failed:
                message = Self.unreachable
            }
        }
    }

    /// Retries the deactivations the server hasn't confirmed. A definite answer settles one (gone
    /// now, or not there to begin with); anything else keeps it for the next sync.
    private func settlePending() async {
        if let settling { return await settling.value }
        let task = Task {
            for item in pending {
                let body = Self.json(["key": item.key, "deviceId": item.id, "target": item.id])
                switch await Self.post(Self.api.appendingPathComponent("deactivate"), body) {
                case .devices, .refused: drop(item)
                case .full, .order, .failed: break
                }
            }
        }
        settling = task
        await task.value
        settling = nil
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
        owner = nil
        ownerDraft = ""
        generation += 1
        save()
        now = Date()
    }

    /// For gallery snapshots only.
    func preview(key: String?, devices: [LicensedMac], firstLaunch: Date, message: String? = nil, serverStatus: String = "ok", owner: String? = nil) {
        previewing = true
        self.key = key
        self.devices = devices
        self.firstLaunch = firstLaunch
        self.message = message
        self.serverStatus = serverStatus
        self.owner = owner
        now = Date()
    }

    private func save() {
        store.set(key, forKey: "license.key")
        store.set(owner, forKey: "license.owner")
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
        /// not_on_key (403) or unknown_key (404), with the server's sentence: no licence for this Mac.
        case refused(String)
        /// limit (409): the key is on three other Macs already.
        case full(String)
        /// order (403): the Mac to remove was activated before this one, and is still in use.
        case order(String)
        /// Anything else, with the HTTP status if there was one: never a verdict.
        case failed(Int?)
    }

    /// The server's {devices} or {error, code}; its dates are ISO 8601 without fractional seconds.
    private struct Answer: Decodable {
        var devices: [LicensedMac]?
        var error: String?
        var code: String?
    }

    /// Only the server's own JSON counts: a 2xx with its {devices}, or an {error} with the code that
    /// goes with its status. A 2xx that doesn't decode, a 403 or 404 without its code (an unknown
    /// route, a Vercel checkpoint page, a proxy), a throttle (503 or 429) or any other status is
    /// `.failed`, whatever its body says.
    nonisolated static func classify(status: Int?, body: Data) -> Reply {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let answer = try? decoder.decode(Answer.self, from: body)
        switch (status ?? 0, answer?.devices, answer?.code, answer?.error) {
        case (200..<300, let devices?, _, _): return .devices(devices)
        case (403, _, "not_on_key"?, let error?), (404, _, "unknown_key"?, let error?): return .refused(error)
        case (409, _, "limit"?, let error?): return .full(error)
        case (403, _, "order"?, let error?): return .order(error)
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
        case .order: "order"
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

    /// Which id this install goes by on the licence server: a random one, made once and kept beside
    /// a hash of the hardware it was made on, which is only ever compared here. Preferences copied to
    /// another Mac (Migration Assistant, a restored backup) bring an id the first Mac still goes by:
    /// on other hardware this install makes its own and leaves that one alone. An id stored before
    /// the hash (none stored) stays and gets this Mac's; with no hardware id (never on a real Mac),
    /// the stored id stays.
    nonisolated static func deviceID(stored: String?, storedHardware: String?, hardware: String?) -> String {
        if let stored, storedHardware == nil || hardware == nil || storedHardware == hardware { return stored }
        return UUID().uuidString
    }

    /// SHA-256 of an IOPlatformUUID with this app's salt: the same in every account on the Mac, and
    /// unlike the UUID itself, no use to any other app. It never leaves the Mac.
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

        // Only the server's verdicts, told by their code, change the licence; anything else keeps it as it is.
        let reply = { (status: Int?, body: String) in classify(status: status, body: Data(body.utf8)) }
        let list = #"{"devices":[{"id":"A","name":"Studio","model":"Mac14,13","activated":"2026-10-21T09:41:00Z","lastSeen":"2026-10-22T08:00:00Z"},{"id":"kQ3vX9_bR2mT7wYc1LpZ0a","name":"Air","model":"Mac15,12","activated":"2026-10-21T10:00:00Z"}]}"#
        guard case .devices(let macs) = reply(200, list), macs.map(\.name) == ["Studio", "Air"],
              macs.map(\.lastSeen) == [ISO8601DateFormatter().date(from: "2026-10-22T08:00:00Z"), nil] else {
            preconditionFailure("a 2xx with {devices} is the list, last seen when the server says")
        }
        let notOnKey = #"{"error":"This Mac isn’t activated with that license.","code":"not_on_key"}"#
        let checkpoint = "<!DOCTYPE html><html><head><title>Vercel Security Checkpoint</title></head><body></body></html>"
        precondition(reply(403, notOnKey) == .refused("This Mac isn’t activated with that license."), "403 not_on_key: off the key")
        precondition(reply(404, #"{"error":"That license key doesn’t exist.","code":"unknown_key"}"#) == .refused("That license key doesn’t exist."),
                     "404 unknown_key: no such key")
        precondition(reply(409, #"{"error":"This license is already active on 3 Macs. Deactivate one first.","code":"limit"}"#)
            == .full("This license is already active on 3 Macs. Deactivate one first."), "409 limit")
        precondition(reply(403, #"{"error":"Not that one.","code":"order"}"#) == .order("Not that one."), "403 order: that removal, not this Mac")
        precondition(reply(404, #"{"error":"Not found."}"#) == .failed(404), "an unknown route's 404 is no verdict")
        precondition(reply(403, #"{"error":"This Mac isn’t activated with that license."}"#) == .failed(403)
            && reply(409, #"{"error":"Full."}"#) == .failed(409), "nor is an error without its code")
        precondition(reply(404, notOnKey) == .failed(404) && reply(403, #"{"error":"x","code":"unknown_key"}"#) == .failed(403)
            && reply(403, #"{"error":"x","code":"limit"}"#) == .failed(403), "nor a code under another status")
        precondition(reply(403, #"{"error":"x","code":"nope"}"#) == .failed(403) && reply(403, #"{"code":"not_on_key"}"#) == .failed(403),
                     "nor an unknown code, or a code without its sentence")
        precondition(reply(200, checkpoint) == .failed(200) && reply(200, "{}") == .failed(200) && reply(201, "") == .failed(201),
                     "a 2xx without the list is an error, not a success")
        precondition(reply(403, checkpoint) == .failed(403) && reply(429, checkpoint) == .failed(429), "a checkpoint page is no verdict")
        precondition(reply(404, "The page could not be found\n\nNOT_FOUND") == .failed(404), "nor is the platform's own 404")
        precondition(reply(403, #"{"error":{"code":"forbidden"}}"#) == .failed(403), "nor someone else's JSON")
        for status in [400, 415, 429, 500, 502, 503] {
            precondition(reply(status, notOnKey) == .failed(status), "\(status) is never a verdict, whatever it says")
        }
        precondition(reply(nil, "") == .failed(nil), "no answer at all")

        // Any Mac may remove one the server hasn't heard from in 30 days; an older server's list goes by activation.
        let day: TimeInterval = 24 * 3600, t = Date()
        let mac = { (activated: TimeInterval, seen: TimeInterval?) in
            LicensedMac(id: "x", name: "Mini", model: "Macmini9,1", activated: t.addingTimeInterval(-activated * day), lastSeen: seen.map { t.addingTimeInterval(-$0 * day) })
        }
        precondition(!mac(90, 29).stale(at: t) && mac(90, 31).stale(at: t), "stale after 30 days unseen")
        precondition(mac(31, nil).stale(at: t) && !mac(29, nil).stale(at: t), "no lastSeen: the activation date stands in")
        precondition(TrialExpiredWindow.due(last: nil, now: t) && TrialExpiredWindow.due(last: t.addingTimeInterval(-day), now: t)
            && !TrialExpiredWindow.due(last: t.addingTimeInterval(-day + 60), now: t), "the Trial Expired window: once a day at most")

        // This Mac's id: random, and kept on the hardware it was made on.
        let here = hardwareHash("6C1E6F5A-0D1B-4D9E-9C1A-2F4B8E7D3A10"), there = hardwareHash("0F7A2B44-91C3-4E6A-8B25-7D3E1C9A5F60")
        precondition(here.count == 64 && here != there && !here.contains("6C1E6F5A"), "a salted SHA-256, one per Mac")
        precondition(hardwareHash("00000000-0000-0000-0000-000000000000")
            == "10a2f3353f802bd66caf20f7a60c95285aac39553629ea6d46ec75977bf3fcb6", "SHA-256 of app.isola.mac/license-device:<IOPlatformUUID>")
        let made = deviceID(stored: nil, storedHardware: nil, hardware: here)
        precondition(UUID(uuidString: made) != nil && made != deviceID(stored: nil, storedHardware: nil, hardware: here), "a new install makes a random id")
        precondition(deviceID(stored: made, storedHardware: here, hardware: here) == made, "and keeps it")
        precondition(deviceID(stored: "4F6C3B9E-UUID", storedHardware: nil, hardware: here) == "4F6C3B9E-UUID", "an id from before the hash stays")
        let copy = deviceID(stored: made, storedHardware: there, hardware: here)
        precondition(UUID(uuidString: copy) != nil && copy != made, "copied from another Mac: an id of its own, the other Mac's left alone")
        precondition(deviceID(stored: made, storedHardware: there, hardware: nil) == made, "no hardware id: the stored one stays")
        precondition(UUID(uuidString: deviceID(stored: nil, storedHardware: nil, hardware: nil)) != nil, "or a random one stands in")
        precondition(hardwareID().map { $0.count == 64 } ?? true, "this Mac's own")
        selfCheckCopiedPreferences()
    }

    /// Preferences from before the hardware hash, and preferences that came from another Mac, in a
    /// scratch defaults file (a path as the suite name keeps it out of ~/Library/Preferences).
    private static func selfCheckCopiedPreferences() {
        guard let hardware = hardwareID() else { return }
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("isola-license-selfcheck-\(UUID().uuidString)").path
        guard let store = UserDefaults(suiteName: suite) else { return }
        defer {
            store.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let key = makeKey(seed: 7)
        store.set(key, forKey: "license.key")
        store.set("4F6C3B9E-UUID", forKey: "license.deviceID")
        store.set(true, forKey: "license.registered")
        let legacy = License(store: store)
        precondition(legacy.thisMac.id == "4F6C3B9E-UUID" && legacy.registered && legacy.pendingDeactivations == 0,
                     "an id from before the hash: kept and still registered, nothing queued to retire it")
        precondition(store.string(forKey: "license.deviceHardware") == hardware, "and stamped with this Mac's hash")

        // The same preferences on another Mac, with a deactivation of the first Mac still queued.
        store.set(hardwareHash("0F7A2B44-91C3-4E6A-8B25-7D3E1C9A5F60"), forKey: "license.deviceHardware")
        store.set(try? JSONEncoder().encode([Pending(key: key, id: "4F6C3B9E-UUID")]), forKey: "license.pending")
        let copied = License(store: store)
        precondition(copied.thisMac.id != "4F6C3B9E-UUID" && UUID(uuidString: copied.thisMac.id) != nil, "copied from another Mac: a random id of its own")
        precondition(!copied.registered && copied.pendingDeactivations == 0 && copied.key == key,
                     "which registers before it counts, and leaves the other Mac's id and queue alone")
        precondition(store.string(forKey: "license.deviceID") == copied.thisMac.id && store.string(forKey: "license.deviceHardware") == hardware,
                     "this Mac's from now on")

        // "Licensed to" comes back from this Mac's preferences, and fills the activation field.
        store.set("alex@example.com", forKey: "license.owner")
        let named = License(store: store)
        precondition(named.owner == "alex@example.com" && named.ownerDraft == "alex@example.com", "the owner stays in this Mac's preferences")
        // Back to the trial (this Mac deactivated, or the server's no): the next activation starts without it.
        named.revoke(nil)
        precondition(named.owner == nil && named.ownerDraft.isEmpty && License(store: store).ownerDraft.isEmpty, "the owner goes with the key")
    }

    private static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

/// Once a day (unless turned off), the website's releases.json against this build: a newer
/// release is announced in the island unless the prompt is silenced or snoozed. Tapping it, or
/// Update… in Settings, opens the update window.
@MainActor @Observable
final class Updates {
    static let shared = Updates()
    static let feed = URL(string: "https://isola-ruby.vercel.app/releases.json")!
    /// Ed25519 public key (base64) of the key that signs release zips (mac/scripts/update_key.swift).
    nonisolated static let signingKey = "Zuf0t4dE6ZtQNei140hgrqadGenuT4w/hkyKkfZt7rI="
    /// A zip without that key's signature is never unzipped: the download page opens instead.
    nonisolated static let unsigned = "The download isn’t signed by Isola, so it wasn’t installed. Get it from the download page instead."

    /// A release in releases.json. `url` is its download page; `zip` (Isola.app zipped with
    /// `ditto -c -k --keepParent`), its `sha256` and its Ed25519 `signature` (base64, by the key
    /// `signingKey` is the public half of) let Update Now… install it in place.
    struct Release: Decodable, Equatable {
        var version: String
        var build: Int?
        var url: URL
        var notes: String?
        var zip: URL?
        var sha256: String?
        var signature: String?
        var changes: Changes?

        /// Anything for the update window's panel: notes, or a section with changes in it.
        var hasNotes: Bool {
            notes != nil || [changes?.features, changes?.fixes, changes?.important].contains { $0?.isEmpty == false }
        }
    }

    /// What's new, by section of the update window.
    struct Changes: Decodable, Equatable {
        var features: [String]?
        var fixes: [String]?
        var important: [String]?
    }

    /// releases.json: the stable release at the top level, an early-bird one under "beta".
    struct Feed: Decodable {
        var stable: Release
        var beta: Release?

        private enum Keys: String, CodingKey { case beta }

        init(from decoder: Decoder) throws {
            stable = try Release(from: decoder)
            // A beta that doesn't decode leaves the stable release alone.
            beta = try? decoder.container(keyedBy: Keys.self).decodeIfPresent(Release.self, forKey: .beta)
        }

        /// The beta for early birds when it's the newer one, else the stable release.
        func pick(earlyBird: Bool) -> Release {
            guard earlyBird, let beta, Updates.isNewer(beta.version, build: beta.build, than: stable.version, build: stable.build) else { return stable }
            return beta
        }
    }

    /// Update Now… → Waiting… → Downloading… → Installing… → ready for Restart Isola….
    enum Phase: Equatable {
        case idle, waiting
        case downloading(Double)
        case installing
        /// The new Isola.app, unzipped and checked, waiting in a temporary folder.
        case ready(URL)
        case failed(String)
    }

    var silenced = UserDefaults.standard.bool(forKey: "updates.silenced") {
        didSet { UserDefaults.standard.set(silenced, forKey: "updates.silenced") }
    }
    /// Off: no daily check. Check for Updates… still asks.
    var automatic = UserDefaults.standard.object(forKey: "updates.automatic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "updates.automatic") }
    }
    /// Also offers releases that are still being tested (releases.json's "beta").
    var earlyBird = UserDefaults.standard.bool(forKey: "updates.earlyBird") {
        didSet {
            UserDefaults.standard.set(earlyBird, forKey: "updates.earlyBird")
            // What's on offer changes now, offline too: picked again from the last releases.json, so a
            // beta Check for Updates… found goes when Early bird does. Automatic checks also look again
            // now; without them Isola checks only when asked.
            available = Self.offer(latest, earlyBird: earlyBird)
            if automatic, Self.current != nil { check() }
        }
    }
    /// Remind Me Later: no island prompt until then.
    private(set) var snoozedUntil = UserDefaults.standard.object(forKey: "updates.snoozedUntil") as? Date {
        didSet { UserDefaults.standard.set(snoozedUntil, forKey: "updates.snoozedUntil") }
    }
    private(set) var available: Release?
    /// The last releases.json that decoded, which `available` is picked from.
    @ObservationIgnored private var latest: Feed?
    private(set) var lastCheck = UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date
    private(set) var failed = false
    private(set) var phase = Phase.idle
    /// The release `phase` is about: the update window for another one starts from idle (`phase(of:)`).
    private(set) var updating: Release?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var download: NSKeyValueObservation?

    /// This build, e.g. ("1.4.7", 151); nil when running unbundled (gallery, swift run).
    nonisolated static var current: (version: String, build: Int?)? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        return (version, (info?["CFBundleVersion"] as? String).flatMap { Int($0) })
    }

    func start() {
        // The update window for a stand-in release (zip=, sha256= and signature= make Update Now… real), and the state.
        Debug.on("update.dialog") { args in
            var release = Self.sample
            release.version = args["version"] ?? release.version
            release.build = args["build"].flatMap(Int.init) ?? release.build
            release.zip = args["zip"].flatMap(URL.init(string:))
            release.sha256 = args["sha256"]
            release.signature = args["signature"]
            UpdateWindow.show(release)
        }
        Debug.on("update.state") { _ in
            let u = Updates.shared
            Debug.reply("automatic=\(u.automatic) earlyBird=\(u.earlyBird) silenced=\(u.silenced) snoozedUntil=\(u.snoozedUntil?.formatted() ?? "none") "
                + "available=\(u.available?.version ?? "none") phase=\(u.phase)")
        }
        guard Self.current != nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updates.shared.checkIfDue() }
        }
    }

    /// Hourly. Failed checks aren't recorded, so this retries them.
    private func checkIfDue() {
        let due = automatic && Date().timeIntervalSince(lastCheck ?? .distantPast) >= 24 * 3600
        if let until = snoozedUntil, until <= Date() {
            snoozedUntil = nil
            // Remind Me Later is over: the prompt comes back now, unless the check below brings it.
            if !due, let available, !silenced { Island.shared.post(Self.prompt(available), duration: 8) }
        }
        if due { check() }
    }

    /// `manual` (Check for Updates…) opens the update window when there's one.
    func check(manual: Bool = false) {
        URLSession.shared.dataTask(with: Self.feed) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let feed = ok ? data.flatMap { try? JSONDecoder().decode(Feed.self, from: $0) } : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { Updates.shared.received(feed, manual: manual) } }
        }.resume()
    }

    /// Picked with Early bird as it is when the answer comes, not as it was when the check started.
    private func received(_ feed: Feed?, manual: Bool) {
        failed = feed == nil
        guard let feed, Self.current != nil else { return }
        latest = feed
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: "updates.lastCheck")
        available = Self.offer(feed, earlyBird: earlyBird)
        guard let available else { return }
        if manual {
            UpdateWindow.show(available)
        } else if !silenced, !(snoozedUntil.map { $0 > Date() } ?? false) {
            Island.shared.post(Self.prompt(available), duration: 8)
        }
    }

    /// What's on offer in `feed` with Early bird on or off: its release, when it's newer than this build.
    static func offer(_ feed: Feed?, earlyBird: Bool, current: (version: String, build: Int?)? = Updates.current) -> Release? {
        guard let release = feed?.pick(earlyBird: earlyBird), let current,
              isNewer(release.version, build: release.build, than: current.version, build: current.build) else { return nil }
        return release
    }

    func snooze() {
        snoozedUntil = Date().addingTimeInterval(24 * 3600)
    }

    // MARK: - Update Now… and Restart Isola…

    /// Where Update Now… is for `release`: another release's download, staged app or error isn't its.
    func phase(of release: Release) -> Phase { release == updating ? phase : .idle }

    /// Downloads the zip, checks it and unzips it to a temporary folder, ready for Restart Isola….
    /// Without a zip and what checks it, or where Isola can't replace itself (a disk image, a folder
    /// it can't write), it opens the download page instead and returns false. So does a zip that
    /// turns out not to be signed, once downloaded.
    @discardableResult
    func install(_ release: Release) -> Bool {
        guard let zip = release.zip, ["https", "file"].contains(zip.scheme), let sha256 = release.sha256, release.signature != nil,
              Self.installTarget() != nil else {
            NSWorkspace.shared.open(release.url)
            return false
        }
        updating = release
        phase = .waiting
        let task = URLSession.shared.downloadTask(with: zip) { file, response, _ in
            // The download is deleted when this returns: check and unzip it here, off the main thread.
            let result: Phase
            if let file, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 {
                DispatchQueue.main.async { MainActor.assumeIsolated { if Updates.shared.updating == release { Updates.shared.phase = .installing } } }
                result = Self.unpack(file, sha256: sha256, release: release)
            } else {
                result = .failed("Couldn’t download the update. Check your connection and try again.")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let u = Updates.shared
                    guard u.updating == release else { return }  // Update Now… for another release since
                    u.download = nil
                    u.phase = result
                    if result == .failed(Self.unsigned) { NSWorkspace.shared.open(release.url) }
                }
            }
        }
        download = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let u = Updates.shared
                    switch u.phase(of: release) {
                    case .waiting, .downloading: if fraction > 0 { u.phase = .downloading(fraction) }
                    default: break
                    }
                }
            }
        }
        task.resume()
        return true
    }

    /// The zip, checked against the release's SHA-256 and signature (`key`'s), then unzipped into a
    /// new temporary folder: ready when the Isola.app inside is this release.
    nonisolated static func unpack(_ zip: URL, sha256: String, release: Release, key: String = signingKey) -> Phase {
        guard let data = try? Data(contentsOf: zip), SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
            return .failed("The download doesn’t match this release, so it wasn’t installed.")
        }
        guard verify(data, signature: release.signature, key: key) else { return .failed(unsigned) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Isola-update-\(UUID().uuidString)")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try? ditto.run()
        ditto.waitUntilExit()
        let app = folder.appendingPathComponent("Isola.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard ditto.terminationStatus == 0, info?["CFBundleIdentifier"] as? String == "app.isola.mac",
              info?["CFBundleShortVersionString"] as? String == release.version,
              release.build.map({ String($0) == info?["CFBundleVersion"] as? String }) ?? true else {
            try? FileManager.default.removeItem(at: folder)
            return .failed("The download isn’t Isola \(release.version), so it wasn’t installed.")
        }
        return .ready(app)
    }

    /// `signature` (base64) is the Ed25519 signature of `data` by the key whose public half is `key` (base64).
    nonisolated static func verify(_ data: Data, signature: String?, key: String = signingKey) -> Bool {
        guard let signature = signature.flatMap({ Data(base64Encoded: $0) }), let raw = Data(base64Encoded: key),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// This Isola.app, if Isola can replace it.
    nonisolated static func installTarget(_ app: URL = Bundle.main.bundleURL) -> URL? {
        let files = FileManager.default
        guard app.pathExtension == "app", files.isWritableFile(atPath: app.path), files.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            return nil
        }
        return app
    }

    /// Restart Isola… with `release` staged: the relaunch script takes over, and Isola quits.
    func restart(_ release: Release) {
        guard case .ready(let app) = phase(of: release), let target = Self.installTarget() else { return }
        do {
            _ = try Self.swap(app, into: target, after: ProcessInfo.processInfo.processIdentifier, open: "/usr/bin/open")
            NSApp.terminate(nil)
        } catch {
            phase = .failed("Couldn’t restart Isola. Quit it and open it again.")
        }
    }

    /// Starts the relaunch script, which outlives Isola: once `pid` has quit it moves the new app
    /// into place (putting the old one back if that fails) and opens whichever is there.
    nonisolated static func swap(_ app: URL, into target: URL, after pid: Int32, open: String) throws -> Process {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", relaunch, "isola-update", String(pid), target.path, app.path, open]
        script.standardError = FileHandle.nullDevice  // a failed mv says so here; the script already handles it
        try script.run()
        return script
    }

    /// $1 the process to wait for, $2 the app to replace, $3 the new app, $4 what opens it.
    nonisolated static let relaunch = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.previous"
        if mv "$2" "$2.previous"; then
          if mv "$3" "$2"; then rm -rf "$2.previous"; else mv "$2.previous" "$2"; fi
        fi
        "$4" "$2"
        """

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
            Island.shared.dismissTransient()
            UpdateWindow.show(release)
        }
    }

    /// For gallery snapshots only.
    func preview(_ release: Release?, checked: Date?) {
        available = release
        lastCheck = checked
        phase = .idle
    }

    static let sample = Release(
        version: "1.5", build: 160, url: License.website.appendingPathComponent("download"), notes: "Lock Screen widgets and a faster island.",
        changes: Changes(
            features: ["A Frosted style for the Lock Screen player", "Sunrise and sunset times in the weather widget", "Early bird updates, for new versions before everyone else"],
            fixes: ["The island no longer flickers when a timer ends during a call", "Calendar colours now follow the setting on the Lock Screen"],
            important: ["Isola restarts once to finish updating."]
        )
    )

    static func gallery() {
        precondition(isNewer("1.5", build: nil, than: "1.4.7", build: 151) && isNewer("1.4.10", build: nil, than: "1.4.9", build: nil), "newer version")
        precondition(isNewer("1.4.7", build: 152, than: "1.4.7", build: 151) && !isNewer("1.4.7", build: 151, than: "1.4.7", build: 151), "same version, by build")
        precondition(!isNewer("1.4", build: nil, than: "1.4.0", build: nil) && !isNewer("1.3.9", build: 999, than: "1.4", build: 1), "equal or older")
        // releases.json as published today, then with sections and a beta for early birds.
        let feed = { (json: String) in try! JSONDecoder().decode(Feed.self, from: Data(json.utf8)) }
        let today = #"{"version":"1.4.7","build":151,"published_at":"2026-10-09T16:12:00.000Z","minimum_system_version":"15 Sequoia","url":"https://isola-ruby.vercel.app/download"}"#
        precondition(feed(today).stable.build == 151 && feed(today).beta == nil && feed(today).pick(earlyBird: true).version == "1.4.7", "today's releases.json")
        let both = #"{"version":"1.4.7","build":151,"url":"https://isola-ruby.vercel.app/download","changes":{"features":["Frosted"],"fixes":["Rain"]},"#
            + #""beta":{"version":"1.5","build":160,"url":"https://isola-ruby.vercel.app/download","zip":"https://isola-ruby.vercel.app/downloads/Isola-1.5.zip","sha256":"00"}}"#
        precondition(feed(both).pick(earlyBird: false).version == "1.4.7" && feed(both).pick(earlyBird: true).zip != nil, "early birds get the newer beta")
        precondition(feed(both).stable.changes == Changes(features: ["Frosted"], fixes: ["Rain"], important: nil), "what's new, by section")
        precondition(feed(both.replacingOccurrences(of: #""version":"1.5""#, with: #""version":"1.4.6""#)).pick(earlyBird: true).version == "1.4.7",
                     "an older beta: the stable release")
        // What's on offer is picked again from the last releases.json when Early bird changes: turned off, offline or not, its beta goes.
        precondition(offer(feed(both), earlyBird: true, current: ("1.4.7", 151))?.version == "1.5" && offer(feed(both), earlyBird: false, current: ("1.4.7", 151)) == nil
                     && offer(feed(both), earlyBird: true, current: nil) == nil, "Early bird's pick, when it's newer than this build")
        precondition(feed(#"{"version":"1.4.7","url":"https://isola-ruby.vercel.app/download","beta":{"version":"1.5"}}"#).beta == nil,
                     "a beta that doesn't decode is left out")
        precondition(!feed(today).stable.hasNotes && feed(both).stable.hasNotes && !Release(version: "1.5", url: sample.url, changes: Changes(fixes: [])).hasNotes,
                     "the update window's panel only with something in it")
        selfCheckInstall()

        // Update Now… belongs to the release it was for: the window for 1.6 starts from idle, not with 1.5's staged app.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("Isola.app")
        var next = sample
        next.version = "1.6"
        shared.updating = sample
        shared.phase = .ready(staged)
        precondition(shared.phase(of: sample) == .ready(staged) && shared.phase(of: next) == .idle, "a staged 1.5 isn't 1.6's")

        Gallery.island("update-available-pill", item: prompt(sample))
        Gallery.island("update-available-notch", item: prompt(sample), geometry: .notchPreview)
        if let dir = SettingsGallery.directory {
            let mismatch = Phase.failed("The download doesn’t match this release, so it wasn’t installed.")
            let phases: [(String, Phase)] = [
                ("", .idle), ("-waiting", .waiting), ("-downloading", .downloading(0.42)), ("-ready", .ready(staged)), ("-failed", mismatch),
            ]
            for (suffix, phase) in phases {
                shared.phase = phase
                SettingsGallery.capture(UpdateWindow.makeWindow(sample), name: "update-window\(suffix)", dir: dir)
            }
            var plain = sample
            plain.changes = nil
            SettingsGallery.capture(UpdateWindow.makeWindow(plain), name: "update-window-notes", dir: dir)
            // Nothing to list: no empty panel, and a window that fits the rest, growing for an error that comes up later.
            plain.notes = nil
            shared.updating = plain
            shared.phase = .idle
            SettingsGallery.capture(UpdateWindow.makeWindow(plain), name: "update-window-bare", dir: dir)
            let bare = UpdateWindow.makeWindow(plain)
            shared.phase = mismatch
            SettingsGallery.capture(bare, name: "update-window-bare-failed", dir: dir)
        }
        shared.phase = .idle
        // SettingsModule's gallery runs this one: the License tab's other windows render here too.
        License.gallery()
    }

    /// Update Now… and Restart Isola… on stand-in apps in a scratch folder: a zip that matches and is
    /// signed is unzipped, one that doesn't (or isn't signed, or isn't the release offered) is refused,
    /// and the script swaps the new app in, or keeps the old one when it can't.
    private static func selfCheckInstall() {
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent("isola-update-selfcheck-\(UUID().uuidString)")
        var staged: URL?
        defer {
            try? files.removeItem(at: dir)
            if let staged { try? files.removeItem(at: staged.deletingLastPathComponent()) }
        }
        func app(_ path: String, version: String) -> URL {
            let app = dir.appendingPathComponent(path)
            try? files.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": "app.isola.mac", "CFBundleShortVersionString": version, "CFBundleVersion": "160"]
            info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
            return app
        }
        func version(_ app: URL) -> String? {
            NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        }

        // A release zip, made as the release is: ditto -c -k --keepParent Isola.app.
        let zip = dir.appendingPathComponent("Isola.zip"), ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app("build/Isola.app", version: "1.5").path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()
        let data = (try? Data(contentsOf: zip)) ?? Data()
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // Signed as build.sh signs it, by a throwaway key standing in for the release key.
        let signer = Curve25519.Signing.PrivateKey(), key = signer.publicKey.rawRepresentation.base64EncodedString()
        var release = Release(version: "1.5", build: 160, url: sample.url)
        release.signature = try? signer.signature(for: data).base64EncodedString()
        guard case .ready(let new) = unpack(zip, sha256: sha256.uppercased(), release: release, key: key), version(new) == "1.5" else {
            preconditionFailure("a zip that matches the release and its signature unpacks to its Isola.app")
        }
        staged = new
        var flipped = data
        flipped[flipped.count / 2] ^= 1
        precondition(!verify(flipped, signature: release.signature, key: key), "a signature is for those bytes only")
        if case .ready = unpack(zip, sha256: String(repeating: "0", count: 64), release: release, key: key) { preconditionFailure("a zip that doesn't match isn't installed") }
        var withoutSignature = release
        withoutSignature.signature = nil
        precondition(unpack(zip, sha256: sha256, release: release) == .failed(unsigned) && unpack(zip, sha256: sha256, release: withoutSignature, key: key) == .failed(unsigned),
                     "nor one another key signed, or none: the download page instead")
        var other = release
        other.version = "1.6"
        if case .ready = unpack(zip, sha256: sha256, release: other, key: key) { preconditionFailure("nor one that isn't the release offered") }

        // Restart Isola…: the installed app is replaced, then opened (`true` stands in for open).
        let installed = app("Applications/Isola.app", version: "1.4.7")
        precondition(installTarget(installed) == installed && installTarget(URL(fileURLWithPath: "/System/Applications/Calculator.app")) == nil,
                     "only an app Isola can replace")
        (try? swap(new, into: installed, after: 99_999_999, open: "/usr/bin/true"))?.waitUntilExit()
        precondition(version(installed) == "1.5" && !files.fileExists(atPath: new.path) && !files.fileExists(atPath: installed.path + ".previous"),
                     "Restart Isola… swaps the new app in")
        // The new app gone missing: the installed one stays where it is.
        (try? swap(new, into: installed, after: 99_999_999, open: "/usr/bin/true"))?.waitUntilExit()
        precondition(version(installed) == "1.5" && !files.fileExists(atPath: installed.path + ".previous"), "a swap that can't happen keeps the app")
    }
}

/// Settings › License.
struct LicensePage: View {
    @Bindable var license = License.shared

    var body: some View {
        Form {
            Section {
                status
                if license.status == .licensed {
                    LabeledContent("Licensed to") {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let owner = license.owner { Text(owner) }
                            Text(License.mask(license.key)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            switch license.status {
            case .licensed:
                Section {
                    // In activation order: a Mac can remove itself, a Mac activated after it, or one not seen for 30 days.
                    let mine = license.devices.firstIndex { $0.id == license.thisMac.id }
                    ForEach(Array(license.devices.enumerated()), id: \.element.id) { index, mac in
                        deviceRow(mac, removable: (mine.map { index >= $0 } ?? true) || mac.stale(at: license.now))
                    }
                } header: {
                    Text("Activated Macs (\(license.devices.count) of \(License.deviceLimit))")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let message = license.message {
                            Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        }
                        Text("Deactivate a Mac to free a slot for another one. A Mac can remove itself, any Mac activated after it, and any Mac not seen for 30 days."
                            + (license.serverStatus.hasPrefix("offline") ? " Couldn’t reach the license server, so this list may be out of date." : ""))
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .trial, .expired:
                Section {
                    LabeledContent("License key") {
                        TextField("License key", text: $license.draft, prompt: Text("ISOLA-XXXX-XXXX-XXXX"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .onSubmit { license.activate(license.draft, owner: license.ownerDraft) }
                    }
                    LabeledContent("Name or e-mail") {
                        TextField("Name or e-mail", text: $license.ownerDraft, prompt: Text("Optional"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        if let message = license.message {
                            Label(message, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                        Spacer()
                        Button("Activate") { license.activate(license.draft, owner: license.ownerDraft) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(license.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Activate")
                } footer: {
                    Text("The name or e-mail is optional: it labels the license here, stays on this Mac and is never sent to the license server.")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            UpdatesSection()
        }
        .formStyle(.grouped)
        // Every time the tab is shown: switching to it, and the Settings window opening on it or
        // coming back to the front.
        .onAppear { license.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === SettingsWindow.window { license.refresh() }
        }
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
                Text(mac.id != license.thisMac.id && mac.stale(at: license.now)
                    ? "\(mac.model) · last seen \((mac.lastSeen ?? mac.activated).formatted(.relative(presentation: .named)))"
                    : "\(mac.model) · since \(mac.activated.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deactivate") { license.deactivate(mac.id) }
                .disabled(!removable)
                .help(removable ? "" : "Activated before this Mac and seen in the last 30 days: only that Mac, or one activated before it, can remove it.")
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

/// License › Updates. Any grouped Form can show it (About too).
struct UpdatesSection: View {
    @Bindable var updates = Updates.shared

    var body: some View {
        Section {
            LabeledContent {
                if let release = updates.available {
                    Button("Update…") { UpdateWindow.show(release) }
                } else {
                    Button("Check for Updates…") { updates.check(manual: true) }
                }
            } label: {
                Text(title)
                Text(detail)
            }
            Toggle("Check for updates automatically", isOn: $updates.automatic)
            Toggle("Early bird updates", isOn: $updates.earlyBird)
            Toggle("Silence update prompt", isOn: $updates.silenced).disabled(!updates.automatic)
        } header: {
            Text("Updates")
        } footer: {
            Text((updates.automatic ? "Isola checks once a day and shows a new version in the island. Silenced, it only appears here." : "Isola checks only when you ask.")
                + " Early bird updates bring new versions while they’re still being tested.")
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        if let release = updates.available { return "Isola \(release.version) is available" }
        if updates.failed { return "Couldn’t check for updates" }
        return updates.lastCheck == nil ? "Not checked yet" : "Isola is up to date"
    }

    /// Release notes when there's an update, else this build and when it was last checked.
    private var detail: String {
        if let notes = updates.available?.notes { return notes }
        let build = Updates.current.map { "Version \($0.version)" + ($0.build.map { " (\($0))" } ?? "") } ?? "Development build"
        guard let checked = updates.lastCheck else { return build }
        return "\(build) · checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

/// The update window: what's new, then Remind Me Later, or Update Now… and Restart Isola….
struct UpdateView: View {
    var release: Updates.Release
    @Bindable var updates = Updates.shared
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Isola \(release.version) is available").font(.title2.bold())
                    Text(Updates.current.map { "You have version \($0.version)" + ($0.build.map { " (\($0))" } ?? "") + "." } ?? "You have a development build.")
                        .foregroundStyle(.secondary)
                }
            }
            if release.hasNotes {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let notes = release.notes { Text(notes) }
                        changes("New Features", release.changes?.features)
                        changes("Bug Fixes", release.changes?.fixes)
                        changes("Important", release.changes?.important)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            }
            HStack(spacing: 10) {
                progress.font(.callout)
                Spacer(minLength: 0)
                if case .ready = phase {
                    Button("Restart Isola…") { updates.restart(release) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Remind Me Later") {
                        updates.snooze()
                        close()
                    }
                    Button("Update Now…") { if !updates.install(release) { close() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 20)
        // Notes scroll in a window of their own size; without any it's just the header and the buttons.
        .frame(width: 520, height: release.hasNotes ? 460 : nil)
    }

    /// Update Now…'s progress for this release (not another one's).
    private var phase: Updates.Phase { updates.phase(of: release) }

    private var busy: Bool {
        switch phase {
        case .waiting, .downloading, .installing: true
        default: false
        }
    }

    @ViewBuilder private func changes(_ title: String, _ items: [String]?) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var progress: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .waiting:
            status("Waiting…", nil)
        case .downloading(let fraction):
            status("Downloading…", fraction)
        case .installing:
            status("Installing…", nil)
        case .ready:
            Text("Ready. Isola restarts to finish updating.").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ text: String, _ fraction: Double?) -> some View {
        HStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum UpdateWindow {
    private static var window: NSWindow?

    /// From the island prompt, Update… in Settings, and Check for Updates… when it finds one.
    static func show(_ release: Updates.Release) {
        window?.close()
        let w = makeWindow(release)
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    static func makeWindow(_ release: Updates.Release) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        w.title = "Isola Update"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: UpdateView(release: release) { [weak w] in w?.close() })
        w.contentView = host
        w.setContentSize(host.fittingSize)
        return w
    }
}

/// Key field and Activate, with Lost your license? and Buy Isola…: activating outside Settings
/// (the Trial Expired window; an onboarding step can show it too).
struct LicenseActivationForm: View {
    @Bindable var license = License.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("License key", text: $license.draft, prompt: Text("ISOLA-XXXX-XXXX-XXXX"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { license.activate(license.draft) }
                Button("Activate") { license.activate(license.draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(license.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message = license.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Link("Lost your license?", destination: License.website.appendingPathComponent("recover"))
                Spacer()
                Button("Buy Isola…") { NSWorkspace.shared.open(License.website) }
            }
            .font(.callout)
        }
    }
}

/// "Trial Expired": Isola keeps working, so it only asks; closing it is fine.
struct TrialExpiredView: View {
    @Bindable var license = License.shared
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: AppIcon.image).resizable().frame(width: 80, height: 80)
            if license.status == .licensed {
                VStack(spacing: 6) {
                    Text("Isola is licensed").font(.title2.bold())
                    Text("Thanks for supporting Isola.").foregroundStyle(.secondary)
                }
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            } else {
                VStack(spacing: 6) {
                    Text("Trial Expired").font(.title2.bold())
                    Text("Your trial has ended. Isola keeps working, but please activate it to support its development.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LicenseActivationForm(license: license)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 420)
    }
}

/// Opens when the trial runs out, and at launch while it's over: once a day at most.
@MainActor
enum TrialExpiredWindow {
    private static var window: NSWindow?

    /// True when it opened.
    static func showIfDue(now: Date = Date()) -> Bool {
        guard due(last: UserDefaults.standard.object(forKey: "license.expiredShown") as? Date, now: now) else { return false }
        UserDefaults.standard.set(now, forKey: "license.expiredShown")
        show()
        return true
    }

    nonisolated static func due(last: Date?, now: Date) -> Bool {
        now.timeIntervalSince(last ?? .distantPast) >= 24 * 3600
    }

    /// In front, without taking the keyboard from the app in use (also `isolactl license.trialExpired`).
    static func show() {
        window?.close()
        let w = makeWindow()
        w.center()
        window = w
        w.orderFrontRegardless()
    }

    static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Trial Expired"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: TrialExpiredView { [weak w] in w?.close() })
        w.contentView = host
        w.setContentSize(host.fittingSize)
        return w
    }
}

extension License {
    /// The Trial Expired window and the License page with a name; SettingsGallery renders the rest.
    static func gallery() {
        guard let dir = SettingsGallery.directory else { return }
        let license = License.shared, ended = Date().addingTimeInterval(-80 * 3600)
        license.preview(key: nil, devices: [], firstLaunch: ended)
        SettingsGallery.capture(TrialExpiredWindow.makeWindow(), name: "license-trial-expired", dir: dir)
        license.draft = "ISOLA-7Q4K-2M9X-AAAA"
        license.preview(key: nil, devices: [], firstLaunch: ended, message: "That doesn’t look like an Isola license key.")
        SettingsGallery.capture(TrialExpiredWindow.makeWindow(), name: "license-trial-expired-error", dir: dir)
        license.draft = ""
        var me = license.thisMac
        me.activated = Date().addingTimeInterval(-3 * 24 * 3600)
        license.preview(key: makeKey(seed: 7), devices: [me], firstLaunch: ended, owner: "alex@example.com")
        SettingsGallery.capture(TrialExpiredWindow.makeWindow(), name: "license-trial-expired-thanks", dir: dir)
        SettingsGallery.window("settings-license-licensed-owner", section: "license")
        // Whole pages (the window crops them): licensed with an update on offer, and the trial.
        Updates.shared.preview(Updates.sample, checked: Date().addingTimeInterval(-2 * 3600))
        SettingsGallery.snapshot("license-page-licensed", size: CGSize(width: 520, height: 820)) { LicensePage() }
        Updates.shared.preview(nil, checked: nil)
        license.preview(key: nil, devices: [], firstLaunch: Date().addingTimeInterval(-10 * 3600))
        SettingsGallery.snapshot("license-page-trial", size: CGSize(width: 520, height: 820)) { LicensePage() }
    }
}
