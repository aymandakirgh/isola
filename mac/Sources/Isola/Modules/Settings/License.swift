import AppKit
import Observation
import SwiftUI

struct LicensedMac: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var model: String
    var activated: Date
}

/// Trial + licence state. Mirrors the website's mock licensing: keys are validated
/// locally (format + checksum) and up to three Macs can be activated.
@MainActor @Observable
final class License {
    static let shared = License()
    static let trialLength: TimeInterval = 72 * 3600
    static let deviceLimit = 3
    static let website = URL(string: "https://isola-ruby.vercel.app")!
    /// Key handed out by the website's demo checkout (/purchased/demo).
    static let demoKey = "ISOLA-DEMO-7Q4K-2M9X"
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private(set) var key: String?
    private(set) var devices: [LicensedMac]
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
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        key = store.string(forKey: "license.key")
        devices = (store.data(forKey: "license.devices")).flatMap { try? JSONDecoder().decode([LicensedMac].self, from: $0) } ?? []
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

    @discardableResult
    func activate(_ raw: String) -> Bool {
        let candidate = Self.normalize(raw)
        guard Self.isValid(candidate) else {
            message = "That doesn’t look like an Isola license key."
            return false
        }
        if !devices.contains(where: { $0.id == thisMac.id }) {
            guard devices.count < Self.deviceLimit else {
                message = "This license is already active on \(Self.deviceLimit) Macs. Deactivate one first."
                return false
            }
            var mac = thisMac
            mac.activated = Date()
            devices.append(mac)
        }
        key = candidate
        draft = ""
        message = nil
        save()
        return true
    }

    func deactivate(_ id: String) {
        devices.removeAll { $0.id == id }
        if id == thisMac.id { key = nil }
        save()
    }

    func reset() {
        key = nil
        devices = []
        firstLaunch = Date()
        store.set(firstLaunch, forKey: "license.firstLaunch")
        message = nil
        save()
        now = Date()
    }

    /// For gallery snapshots only.
    func preview(key: String?, devices: [LicensedMac], firstLaunch: Date, message: String? = nil) {
        self.key = key
        self.devices = devices
        self.firstLaunch = firstLaunch
        self.message = message
        now = Date()
    }

    private func save() {
        store.set(key, forKey: "license.key")
        store.set(try? JSONEncoder().encode(devices), forKey: "license.devices")
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
    }

    private static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

/// Settings › License.
struct LicensePage: View {
    @Bindable var license = License.shared

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
                    Text("Deactivate a Mac to free a slot for another one.")
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
        }
        .formStyle(.grouped)
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
