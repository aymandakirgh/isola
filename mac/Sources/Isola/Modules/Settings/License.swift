import AppKit
import Observation
import SwiftUI

struct LicensedMac: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var model: String
    var activated: Date
}

/// Trial + licence state. Keys are checked here (format + checksum), then registered with the
/// website's licence server (api/license.ts), which keeps each key's Macs, up to three. When the
/// server can't be reached or fails, the local check and the last known list stand in: an outage
/// never takes a licence away, while a definite answer from the server (4xx) does.
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
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private(set) var key: String?
    private(set) var devices: [LicensedMac]
    /// The server has this Mac on `key`: false after an offline activation, until it's registered.
    private(set) var registered: Bool
    /// What the licence server last said: "none" (not asked yet), "ok", "offline" or "refused-<status>".
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
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        key = store.string(forKey: "license.key")
        devices = (store.data(forKey: "license.devices")).flatMap { try? JSONDecoder().decode([LicensedMac].self, from: $0) } ?? []
        registered = store.bool(forKey: "license.registered")
        firstLaunch = store.object(forKey: "license.firstLaunch") as? Date ?? Date()
        let id = store.string(forKey: "license.deviceID") ?? UUID().uuidString
        store.set(id, forKey: "license.deviceID")
        thisMac = LicensedMac(id: id, name: Host.current().localizedName ?? "This Mac", model: Self.modelIdentifier(), activated: Date())
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

    /// Checks the key here, then registers this Mac with the licence server.
    func activate(_ raw: String) {
        let candidate = Self.normalize(raw)
        guard Self.isValid(candidate) else {
            message = "That doesn’t look like an Isola license key."
            return
        }
        message = nil
        Task { await register(candidate) }
    }

    private func register(_ candidate: String) async {
        let before = key
        let device = ["id": thisMac.id, "name": thisMac.name, "model": thisMac.model]
        let answer = await ask("activate", ["key": candidate, "device": device])
        guard key == before else { return }  // deactivated meanwhile
        guard let answer else { return activateLocally(candidate) }
        guard answer.ok else { return refused(answer, key: candidate) }
        key = candidate
        devices = answer.devices ?? [thisMac]
        registered = true
        draft = ""
        message = nil
        save()
    }

    /// Offline: the checksum and a local list of up to three Macs, as before the server. The next
    /// `refresh()` registers the Mac.
    private func activateLocally(_ candidate: String) {
        if !devices.contains(where: { $0.id == thisMac.id }) {
            guard devices.count < Self.deviceLimit else {
                message = "This license is already active on \(Self.deviceLimit) Macs. Deactivate one first."
                return
            }
            var mac = thisMac
            mac.activated = Date()
            devices.append(mac)
        }
        key = candidate
        registered = false
        draft = ""
        message = nil
        save()
    }

    /// A definite no. For the key this Mac already uses (removed from another Mac, or an offline
    /// activation that doesn't hold) the server wins, and this Mac goes back to the trial.
    private func refused(_ answer: Answer, key candidate: String) {
        message = answer.error ?? "The license server refused this key."
        guard key == candidate else { return }
        key = nil
        devices = []
        registered = false
        save()
    }

    /// Syncs with the server, at launch and when the License tab opens: an offline activation
    /// registers, a registered Mac takes the server's list. Offline, the cached list stays.
    func refresh() {
        guard let key, !previewing else { return }
        Task {
            if !registered { return await register(key) }
            // The shared demo key keeps no list on the server: it's just this Mac.
            guard key != Self.demoKey, let answer = await ask("devices", ["key": key, "deviceId": thisMac.id]),
                  self.key == key else { return }
            guard answer.ok else { return refused(answer, key: key) }
            devices = answer.devices ?? devices
            save()
        }
    }

    /// This Mac always goes, offline too, so nobody is stuck licensed; another Mac needs the server.
    func deactivate(_ id: String) {
        guard let key else { return }
        Task {
            var answer: Answer?
            if key != Self.demoKey { answer = await ask("deactivate", ["key": key, "deviceId": thisMac.id, "target": id]) }
            if id == thisMac.id {
                self.key = nil
                devices = []
                registered = false
                message = nil
            } else if let answer, answer.ok {
                devices = answer.devices ?? devices
                message = nil
            } else {
                message = answer?.error ?? "Couldn’t reach the license server. Try again when you’re online."
            }
            save()
        }
    }

    func reset() {
        key = nil
        devices = []
        registered = false
        serverStatus = "none"
        firstLaunch = Date()
        store.set(firstLaunch, forKey: "license.firstLaunch")
        message = nil
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
    }

    // MARK: - Licence server

    /// An answer from the server: its status, and {devices} or {error}.
    struct Answer: Decodable {
        var status = 0
        var devices: [LicensedMac]?
        var error: String?
        var ok: Bool { (200..<300).contains(status) }

        private enum CodingKeys: CodingKey { case devices, error }

        /// The server's dates are ISO 8601 without fractional seconds.
        static func decode(_ data: Data) -> Answer? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Answer.self, from: data)
        }
    }

    /// POST <api>/<action>, noting the outcome in `serverStatus`. nil when the server can't be
    /// reached, fails (5xx) or answers with anything but its JSON (as before it's deployed).
    private func ask(_ action: String, _ body: [String: Any]) async -> Answer? {
        let url = Self.api.appendingPathComponent(action)
        let answer = await Self.post(url, (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        serverStatus = answer.map { $0.ok ? "ok" : "refused-\($0.status)" } ?? "offline"
        return answer
    }

    private nonisolated static func post(_ url: URL, _ body: Data) async -> Answer? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, status < 500,
              var answer = Answer.decode(data) else { return nil }
        answer.status = status
        return answer
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
        assert(isValid(key), "generated key must validate")
        var tampered = Array(key)
        tampered[6] = tampered[6] == "A" ? "B" : "A"
        assert(!isValid(String(tampered)), "a changed character must fail the checksum")
        assert(isValid(demoKey), "the website demo key is accepted")
        assert(!isValid("ISOLA-ABCD-EFGH"), "too short")
        assert(isValid(normalize(" isola" + key.dropFirst(5).lowercased() + " ")), "case and spaces are forgiven")
        // What the licence server (api/license.ts) mints and answers.
        assert(isValid("ISOLA-U9VJ-DMME-DWJU"), "a key minted by the licence server validates")
        let list = #"{"devices":[{"id":"A","name":"Studio","model":"Mac14,13","activated":"2026-10-21T09:41:00Z"}]}"#
        assert(Answer.decode(Data(list.utf8))?.devices?.first?.name == "Studio", "the server's Mac list decodes")
        let refusal = #"{"error":"This license is already active on 3 Macs. Deactivate one first."}"#
        assert(Answer.decode(Data(refusal.utf8))?.error?.hasPrefix("This license") == true, "a refusal decodes")
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
                    ForEach(license.devices) { mac in deviceRow(mac) }
                } header: {
                    Text("Activated Macs (\(license.devices.count) of \(License.deviceLimit))")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let message = license.message {
                            Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        }
                        Text("Deactivate a Mac to free a slot for another one."
                            + (license.serverStatus == "offline" ? " The license server can’t be reached, so this list may be out of date." : ""))
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
        .onAppear { license.refresh() }
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

    private func deviceRow(_ mac: LicensedMac) -> some View {
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
