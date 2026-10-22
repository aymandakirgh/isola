import AppKit
import Observation

/// "Sync settings with iCloud Drive". iCloud key-value storage needs an entitlement this
/// ad-hoc build can't have, but iCloud Drive is a plain folder that any app outside the
/// sandbox can use and that macOS syncs between the user's Macs. Each Mac keeps a ledger of
/// the synced settings (value, when it last changed, on which Mac) and merges it with
/// `<iCloud Drive>/Isola/Settings.plist` key by key: the most recent change wins.
@MainActor @Observable
final class SettingsSync {
    static let shared = SettingsSync()

    /// A setting as last changed: its value, when, and on which Mac.
    struct Entry {
        var value: Any
        var modified: Date
        var mac: String
    }

    var enabled = UserDefaults.standard.bool(forKey: "sync.enabled") {
        didSet {
            guard enabled != oldValue else { return }
            pending?.invalidate()
            pending = nil
            problem = nil
            lastSync = nil
            seen = nil
            if enabled { seed() } else { ledger = [:]; UserDefaults.standard.removeObject(forKey: "sync.ledger") }
            UserDefaults.standard.set(enabled, forKey: "sync.enabled")
            sync()
        }
    }
    /// Why the last sync didn't complete: no iCloud Drive, file still downloading, an I/O error.
    private(set) var problem: String?
    private(set) var lastSync: Date?
    /// Stands in for iCloud Drive so tests use a scratch folder: ISOLA_SYNC_FOLDER at launch, or `isolactl sync.folder path=…`.
    @ObservationIgnored var folder = ProcessInfo.processInfo.environment["ISOLA_SYNC_FOLDER"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    @ObservationIgnored private var ledger = SettingsSync.decode(UserDefaults.standard.data(forKey: "sync.ledger") ?? Data())
    /// The ledger has changes not yet saved to defaults.
    @ObservationIgnored private var dirty = false
    /// Seeding or applying other Macs' values: the defaults writes that causes aren't local changes.
    @ObservationIgnored private var busy = false
    /// The file's modification date as of the last sync.
    @ObservationIgnored private var seen: Date?
    @ObservationIgnored private var pending: Timer?
    @ObservationIgnored private var writes = 0
    @ObservationIgnored private var applied = 0

    private var root: URL { folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") }
    var file: URL { root.appendingPathComponent("Isola/Settings.plist") }
    private var modified: Date? { (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date }

    /// This Mac in the entries it writes: a random ID, not the license's device ID.
    private var mac: String {
        if let id = UserDefaults.standard.string(forKey: "sync.mac") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "sync.mac")
        return id
    }

    /// The line under the toggle while sync is on.
    var status: String {
        if let problem { return problem }
        guard let lastSync else { return "Not synced yet" }
        return Date().timeIntervalSince(lastSync) < 60 ? "Last synced just now" : "Last synced \(lastSync.formatted(.relative(presentation: .named)))"
    }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsSync.shared.localChange() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsSync.shared.sync() }
        }
        // Quitting inside the debounce still writes the last change.
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if SettingsSync.shared.pending != nil { SettingsSync.shared.sync() } }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { SettingsSync.shared.poll() } }
        registerDebug()
        if enabled, ledger.isEmpty { seed() }
        sync()
    }

    /// Reads the file, applies what other Macs changed more recently and writes back what this
    /// Mac changed more recently. Runs at launch, on activation, when the file changes and a
    /// second after a local change.
    func sync() {
        guard enabled else { return }
        pending?.invalidate()
        pending = nil
        stampLocalChanges()
        defer { if dirty { saveLedger() } }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return problem = "iCloud Drive isn't available" }
        if Self.needsDownload(file) {
            try? fm.startDownloadingUbiquitousItem(at: file)
            return problem = "Waiting for iCloud Drive to download the settings"
        }
        var remote: [String: Entry] = [:]
        if fm.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else { return problem = "Couldn't read the settings in iCloud Drive" }
            remote = Self.decode(data)
        }
        let (merged, incoming, outgoing) = Self.merge(ledger, remote)
        // Other Macs' values go through each setting's own setter, so the island, monitors and the
        // Settings window follow; a sound turned on elsewhere doesn't play its preview here.
        busy = true
        Sounds.muted = true
        let previous = ledger
        ledger = merged
        for (key, entry) in incoming {
            if let old = previous[key], Self.same(old.value, entry.value) { continue }
            Self.live[key]?(entry.value)
            applied += 1
        }
        Sounds.muted = false
        busy = false
        if !incoming.isEmpty { dirty = true }
        if outgoing {
            do {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.encode(ledger).write(to: file, options: .atomic)
                writes += 1
            } catch {
                return problem = "Couldn't save to iCloud Drive"
            }
        }
        seen = modified
        problem = nil
        lastSync = Date()
    }

    /// Every 30 s: a new modification date means another Mac's settings arrived.
    private func poll() {
        guard enabled else { return }
        if problem == nil, modified == seen { lastSync = Date() } else { sync() }
    }

    /// Every defaults write lands here: synced keys whose value moved get this Mac's stamp,
    /// and the file is written a second after the last of a burst (sliders, typing).
    private func localChange() {
        guard enabled, !busy, stampLocalChanges() else { return }
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in MainActor.assumeIsolated { SettingsSync.shared.sync() } }
    }

    @discardableResult private func stampLocalChanges() -> Bool {
        let values = currentValues(), id = mac
        guard Self.stamp(&ledger, values: values, date: Date(), mac: id) else { return false }
        dirty = true
        return true
    }

    /// Turning sync on takes the settings already in iCloud Drive: this Mac's values count as
    /// older than any change recorded there, so they only fill in what the file lacks.
    private func seed() {
        busy = true
        let values = currentValues(), id = mac
        ledger = [:]
        Self.stamp(&ledger, values: values, date: .distantPast, mac: id)
        busy = false
        dirty = true
    }

    private func currentValues() -> [String: Any] {
        Self.keys.reduce(into: [:]) { values, key in values[key] = UserDefaults.standard.object(forKey: key) }
    }

    private func saveLedger() {
        dirty = false
        UserDefaults.standard.set(try? Self.encode(ledger), forKey: "sync.ledger")
    }

    /// Not downloaded yet: a `.Settings.plist.icloud` placeholder, or a dataless file whose read
    /// would block until iCloud fetches it.
    private static func needsDownload(_ file: URL) -> Bool {
        var info = stat()
        if stat(file.path, &info) == 0 { return info.st_flags & UInt32(SF_DATALESS) != 0 }
        return FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud").path)
    }

    // MARK: - What syncs

    /// Synced settings, each with how the live object takes a merged value: through the
    /// property's own setter, as if it was changed on this Mac. Anything not listed stays on
    /// this Mac: license and device ID, onboarding, update checks, window and menu bar
    /// positions, the chosen display and notch fine tuning (this Mac's hardware), hidden
    /// calendars and dismissed events (this Mac's EventKit IDs), the live waveform (it would
    /// ask every Mac for System Audio Recording) and this sync's own state.
    static let live: [String: (Any) -> Void] = {
        let core = Preferences.shared, media = MediaPreferences.shared, system = SystemPreferences.shared
        let hud = HUDPreferences.shared, calendar = CalendarPreferences.shared, lock = LockScreenPreferences.shared
        return [
            "allDisplays": bind(core, \.allDisplays),
            "simulatedNotch": bind(core, \.simulatedNotch),
            "showIdlePill": bind(core, \.showIdlePill),
            "hideInFullscreen": bind(core, \.hideInFullscreen),
            "hideWhileGaming": bind(core, \.hideWhileGaming),
            "hideInMissionControl": bind(core, \.hideInMissionControl),
            "hideFromScreenCapture": bind(core, \.hideFromScreenCapture),
            "outline": bindRaw(core, \.outline),
            "hoverExpandDelay": bind(core, \.hoverExpandDelay),
            "expandWhileInactive": bind(core, \.expandWhileInactive),
            "duo": bind(core, \.duo),
            "notificationDuration": bind(core, \.notificationDuration),
            "naturalSwipe": bind(core, \.naturalSwipe),
            "speed": bindRaw(core, \.speed),
            "overshoot": bind(core, \.overshoot),
            "unlockSound": bind(core, \.unlockSound),
            "lockSound": bind(core, \.lockSound),

            "media.spectrogram": bind(media, \.spectrogram),
            "media.spectrogramStyle": bindRaw(media, \.spectrogramStyle),
            "media.focusReplace": bind(media, \.focusReplace),
            "media.focusMode": bind(media, \.focusMode),
            "media.grayscaleArtwork": bind(media, \.grayscaleArtwork),
            "media.dimOnPause": bind(media, \.dimOnPause),
            "media.artworkGlare": bind(media, \.artworkGlare),
            "media.hideNoteSymbol": bind(media, \.hideNoteSymbol),
            "media.hideTitleExtras": bind(media, \.hideTitleExtras),
            "media.idleSeconds": bind(media, \.idleSeconds),
            "media.excludeBrowsers": bind(media, \.excludeBrowsers),
            "media.excludeInapt": bind(media, \.excludeInapt),
            "media.gradientProgress": bind(media, \.gradientProgress),
            "media.showTotalTime": bind(media, \.showTotalTime),
            "media.keepVolumeOpen": bind(media, \.keepVolumeOpen),

            "system.chargingNotification": bind(system, \.chargingNotification),
            "system.chargingActivity": bind(system, \.chargingActivity),
            "system.hideBatteryPercentage": bind(system, \.hideBatteryPercentage),
            "system.lowBatteryNotification": bind(system, \.lowBatteryNotification),
            "system.lowBatteryThreshold": bind(system, \.lowBatteryThreshold),
            "system.lowBatterySound": bind(system, \.lowBatterySound),
            "system.lowPowerNotification": bind(system, \.lowPowerNotification),
            "system.bluetoothNotification": bind(system, \.bluetoothNotification),
            "system.bluetoothAllDevices": bind(system, \.bluetoothAllDevices),
            "system.deviceImage": bindRaw(system, \.deviceImage),
            "system.deviceLowBattery": bind(system, \.deviceLowBattery),
            "system.deviceLowBatteryThreshold": bind(system, \.deviceLowBatteryThreshold),
            "system.deviceLowBatterySound": bind(system, \.deviceLowBatterySound),
            "system.focusNotification": bind(system, \.focusNotification),
            "system.focusMutedModes": bind(system, \.focusMutedModes),
            "system.focusActivity": bind(system, \.focusActivity),
            "system.sleepFocusSound": bind(system, \.sleepFocusSound),
            "system.lockActivity": bind(system, \.lockActivity),

            "hud.replaceSystemHUD": bind(hud, \.replaceSystemHUD),
            "hud.volume.style": bindRaw(hud, \.volume.style),
            "hud.volume.showPercentage": bind(hud, \.volume.showPercentage),
            "hud.volume.labels": bind(hud, \.volume.labels),
            "hud.volume.duration": bind(hud, \.volume.duration),
            "hud.volume.speed": bindRaw(hud, \.volume.speed),
            "hud.brightness.style": bindRaw(hud, \.brightness.style),
            "hud.brightness.showPercentage": bind(hud, \.brightness.showPercentage),
            "hud.brightness.labels": bind(hud, \.brightness.labels),
            "hud.brightness.duration": bind(hud, \.brightness.duration),
            "hud.brightness.speed": bindRaw(hud, \.brightness.speed),
            "hud.linked": bind(hud, \.linked),
            "hud.displaySymbol": bind(hud, \.displaySymbol),
            "hud.outputStyle": bindRaw(hud, \.outputStyle),
            "hud.showExternalChanges": bind(hud, \.showExternalChanges),
            "hud.betterDisplay": bind(hud, \.betterDisplay),
            "hud.feedbackSound": bind(hud, \.feedbackSound),

            "calendar.liveActivity": bind(calendar, \.liveActivity),
            "calendar.leadMinutes": bind(calendar, \.leadMinutes),
            "calendar.timeToLeave": bind(calendar, \.timeToLeave),
            "calendar.travelMode": bindRaw(calendar, \.travelMode),
            "calendar.leaveBuffer": bind(calendar, \.leaveBuffer),
            "calendar.leaveMinutes": bind(calendar, \.leaveMinutes),
            "calendar.showDeclined": bind(calendar, \.showDeclined),
            "calendar.excludeSubscribed": bind(calendar, \.excludeSubscribed),
            "calendar.colors": bind(calendar, \.calendarColors),
            "calendar.splitAllDay": bind(calendar, \.splitAllDay),
            "calendar.lunar": bind(calendar, \.lunar),
            "calendar.openWith": bind(calendar, \.openWith),
            "calendar.idleActivity": bind(calendar, \.idleActivity),
            "weather.enabled": bind(calendar, \.weather),
            "weather.city": bind(calendar, \.weatherCity),
            "weather.lat": bind(calendar, \.weatherLatitude),
            "weather.lon": bind(calendar, \.weatherLongitude),
            "weather.unit": bind(calendar, \.weatherUnit),
            "weather.emptyDay": bind(calendar, \.weatherOnEmptyDay),

            "lockscreen.enabled": bind(lock, \.enabled),
            "lockscreen.showNowPlaying": bind(lock, \.showNowPlaying),
            "lockscreen.showFocus": bind(lock, \.showFocus),
            "lockscreen.showWeather": bind(lock, \.showWeather),
            "lockscreen.showBattery": bind(lock, \.showBattery),
            "lockscreen.showConnectivity": bind(lock, \.showConnectivity),
            "lockscreen.showCalendar": bind(lock, \.showCalendar),
            "lockscreen.nowPlayingStyle": bindRaw(lock, \.nowPlayingStyle),
            "lockscreen.weatherStyle": bindRaw(lock, \.weatherStyle),
            "lockscreen.nowPlayingOffset": bind(lock, \.nowPlayingOffset),
            "lockscreen.hideWhileInactive": bind(lock, \.hideWhileInactive),
            "lockscreen.hideInstantly": bind(lock, \.hideInstantly),
            "lockscreen.showVolumeControl": bind(lock, \.showVolumeControl),
            "lockscreen.keepAwake": bind(lock, \.keepAwake),
            "lockscreen.showOnScreensaver": bind(lock, \.showOnScreensaver),

            "updates.silenced": bind(Updates.shared, \.silenced),
        ]
    }()
    static let keys = Set(live.keys)

    /// A value of the property's own type; anything else is ignored (and this Mac's value wins back at the next sync).
    private static func bind<O: AnyObject, V>(_ object: O, _ path: ReferenceWritableKeyPath<O, V>) -> (Any) -> Void {
        { if let v = $0 as? V { object[keyPath: path] = v } }
    }

    /// Enum settings are stored by raw value.
    private static func bindRaw<O: AnyObject, V: RawRepresentable>(_ object: O, _ path: ReferenceWritableKeyPath<O, V>) -> (Any) -> Void where V.RawValue == String {
        { if let raw = $0 as? String, let v = V(rawValue: raw) { object[keyPath: path] = v } }
    }

    // MARK: - Merging

    /// Gives this Mac's stamp to synced keys whose value differs from the ledger's.
    @discardableResult
    static func stamp(_ ledger: inout [String: Entry], values: [String: Any], date: Date, mac: String) -> Bool {
        var changed = false
        for (key, value) in values where keys.contains(key) {
            if let entry = ledger[key], same(entry.value, value) { continue }
            ledger[key] = Entry(value: value, modified: date, mac: mac)
            changed = true
        }
        return changed
    }

    /// Key by key, the newest change wins. A tie between two Macs (values from before sync was
    /// on) goes to the file, so a Mac turning sync on takes the settings already there.
    /// `incoming`: entries taken from the file; `outgoing`: the file lacks something newer from here.
    static func merge(_ local: [String: Entry], _ remote: [String: Entry]) -> (ledger: [String: Entry], incoming: [String: Entry], outgoing: Bool) {
        var ledger = local.filter { keys.contains($0.key) }
        var incoming: [String: Entry] = [:]
        var outgoing = false
        for key in keys {
            switch (local[key], remote[key]) {
            case let (l?, r?) where r.modified > l.modified || (r.modified == l.modified && r.mac != l.mac):
                ledger[key] = r
                incoming[key] = r
            case let (nil, r?):
                ledger[key] = r
                incoming[key] = r
            case let (l?, r):
                if r.map({ $0.modified != l.modified || $0.mac != l.mac || !same($0.value, l.value) }) ?? true { outgoing = true }
            case (nil, nil):
                break
            }
        }
        return (ledger, incoming, outgoing)
    }

    static func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    /// Binary plist, so dates keep their sub-second precision through the round trip.
    static func encode(_ entries: [String: Entry]) throws -> Data {
        let plist = entries.mapValues { ["value": $0.value, "modified": $0.modified, "mac": $0.mac] as [String: Any] }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> [String: Entry] {
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [String: Any]] ?? [:]
        return plist.compactMapValues { e in
            guard let value = e["value"], let modified = e["modified"] as? Date, let mac = e["mac"] as? String else { return nil }
            return Entry(value: value, modified: modified, mac: mac)
        }
    }

    // MARK: - isolactl

    private func registerDebug() {
        Debug.on("sync.enable") { SettingsSync.shared.enabled = $0["on"] != "0" }
        // `path=` empty goes back to iCloud Drive.
        Debug.on("sync.folder") { args in
            let s = SettingsSync.shared
            s.folder = args["path"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            s.seen = nil
            s.problem = nil
            s.sync()
        }
        Debug.on("sync.now") { _ in SettingsSync.shared.sync() }
        // The other Mac: `sync.remote key=duo value=true [age=<seconds ago>] [mac=<id>]` writes its change into the
        // file (any key, excluded ones too); this Mac picks it up at the next sync. Scratch folders only.
        Debug.on("sync.remote") { args in
            let s = SettingsSync.shared
            guard s.folder != nil, let key = args["key"], let raw = args["value"] else { return NSLog("isola: sync.remote needs sync.folder, key= and value=") }
            let value: Any = raw == "true" ? true : raw == "false" ? false : Double(raw).map { $0 as Any } ?? raw
            var entries = Self.decode((try? Data(contentsOf: s.file)) ?? Data())
            entries[key] = Entry(value: value, modified: Date().addingTimeInterval(-(Double(args["age"] ?? "") ?? 0)), mac: args["mac"] ?? "other-mac")
            try? FileManager.default.createDirectory(at: s.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.encode(entries).write(to: s.file, options: .atomic)
        }
        Debug.on("sync.state") { _ in
            let s = SettingsSync.shared
            Debug.reply(
                "enabled=\(s.enabled) status=\"\(s.enabled ? s.status : "off")\" file=\(s.file.path) entries=\(s.ledger.count) "
                    + "mac=\(UserDefaults.standard.string(forKey: "sync.mac") ?? "none") writes=\(s.writes) applied=\(s.applied) pending=\(s.pending != nil)"
            )
        }
    }

    // MARK: - Gallery

    /// Runs with the gallery (`Isola --gallery`): Macs A, B and C merging through one file, all in memory.
    static func selfCheck() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // A turns sync on first; its license, onboarding, dismissed events and display stay home.
        var macA: [String: Any] = [
            "duo": false, "hud.volume.style": "white", "media.spectrogram": true,
            "license.key": "ISOLA-AAAA", "onboarded": true, "calendar.dismissed": ["event-1"], "preferredDisplay": "LG UltraFine",
        ]
        var ledgerA: [String: Entry] = [:]
        stamp(&ledgerA, values: macA, date: .distantPast, mac: "A")
        var r = merge(ledgerA, [:])
        precondition(r.outgoing && r.incoming.isEmpty, "sync: the first Mac writes the file")
        var file = decode(try! encode(r.ledger))
        precondition(Set(file.keys) == ["duo", "hud.volume.style", "media.spectrogram"], "sync: excluded keys never leave")
        ledgerA = r.ledger

        // A turns duo on; meanwhile B wrote an older duo, a newer HUD style and its own license key.
        macA["duo"] = true
        precondition(stamp(&ledgerA, values: macA, date: t.addingTimeInterval(20), mac: "A"), "sync: a local change is stamped")
        file["duo"] = Entry(value: false, modified: t, mac: "B")
        file["hud.volume.style"] = Entry(value: "accent", modified: t.addingTimeInterval(10), mac: "B")
        file["license.key"] = Entry(value: "ISOLA-BBBB", modified: t.addingTimeInterval(30), mac: "B")
        r = merge(ledgerA, file)
        precondition(Array(r.incoming.keys) == ["hud.volume.style"] && r.ledger["hud.volume.style"]?.mac == "B", "sync: a newer remote key wins")
        precondition(r.ledger["duo"]?.mac == "A" && r.outgoing, "sync: an older remote key loses, and A writes its newer one back")
        precondition(r.ledger["license.key"] == nil, "sync: excluded keys never arrive")

        // A applies the merge (as the live setters do) and writes it: nothing is left to write.
        for (key, entry) in r.incoming { macA[key] = entry.value }
        ledgerA = r.ledger
        file = decode(try! encode(ledgerA))
        precondition(!stamp(&ledgerA, values: macA, date: t.addingTimeInterval(40), mac: "A"), "sync: applied values aren't local changes")
        r = merge(ledgerA, file)
        precondition(!r.outgoing && r.incoming.isEmpty, "sync: applying a merge produces no new write")

        // B reads A's file: it takes A's newer duo and has nothing to write back.
        let ledgerB = ["duo": Entry(value: false, modified: t, mac: "B"), "hud.volume.style": file["hud.volume.style"]!]
        r = merge(ledgerB, file)
        precondition(r.incoming["duo"].map { same($0.value, true) } == true && !r.outgoing, "sync: the other Mac converges without writing")

        // C turns sync on later: for values unchanged since before sync (a tie), iCloud's wins.
        var ledgerC: [String: Entry] = [:]
        stamp(&ledgerC, values: ["media.spectrogram": false], date: .distantPast, mac: "C")
        precondition(merge(ledgerC, file).incoming["media.spectrogram"].map { same($0.value, true) } == true, "sync: turning sync on takes iCloud's settings")
    }
}
