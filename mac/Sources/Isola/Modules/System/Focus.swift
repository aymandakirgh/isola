import AppKit
import Intents
import SwiftUI

/// Focus modes. The Do Not Disturb database (readable with Full Disk Access) gives the
/// mode's name, symbol and colour; otherwise INFocusStatusCenter tells on/off only.
@MainActor
final class FocusMonitor {
    static let shared = FocusMonitor()

    struct Mode: Equatable {
        var id: String
        var name: String
        var symbol: String
        var tint: NSColor
        /// The name in the user's language (Apple's names for the built-in modes).
        var title: String { FocusL10n.text(name) }
    }

    /// On/off from INFocusStatusCenter alone: which Focus is unknown.
    nonisolated static let genericID = "focus"

    private(set) var current: Mode?
    private var timer: Timer?
    private var pausedUntil = Date.distantPast

    /// Debug simulations hold the poll off so the real state doesn't undo them.
    func pause(for seconds: TimeInterval) { pausedUntil = Date().addingTimeInterval(seconds) }

    func start() {
        apply(Self.read(), announce: false)
        // No public change notification for Focus: a cheap poll.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard Date() > FocusMonitor.shared.pausedUntil else { return }
                let mode = FocusMonitor.read()
                if mode != FocusMonitor.shared.current { FocusMonitor.shared.apply(mode, announce: true) }
            }
        }
    }

    func apply(_ mode: Mode?, announce: Bool) {
        let previous = current
        current = mode
        let state = FocusState.shared
        state.active = mode != nil
        if let mode {
            state.name = mode.title
            state.symbol = mode.symbol
        }
        if announce, SystemPreferences.shared.focusNotification, let shown = mode ?? previous {
            Island.shared.post(FocusItems.changed(shown, on: mode != nil))
        }
        if announce, mode?.id == Self.sleepID, previous?.id != Self.sleepID, SystemPreferences.shared.sleepFocusSound {
            Sounds.sleepFocus()
        }
        syncActivity()
    }

    func syncActivity() {
        if SystemPreferences.shared.focusActivity, let current {
            Island.shared.start(FocusItems.activity(current))
        } else {
            Island.shared.end(FocusItems.activityID)
        }
    }

    nonisolated static func read() -> Mode? {
        if let fromDatabase = readDatabase() { return fromDatabase }
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized, center.focusStatus.isFocused == true else { return nil }
        return Mode(id: genericID, name: "Focus", symbol: "moon.fill", tint: .systemIndigo)
    }

    nonisolated static let database = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")

    /// Full Disk Access, as far as Focus is concerned (status checks never prompt).
    nonisolated static var canReadDatabase: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: database.path)) != nil
    }

    /// `.some(nil)` = database readable and no Focus on; `nil` = can't read it.
    nonisolated static func readDatabase() -> Mode?? {
        let dir = database
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("Assertions.json")),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let id = firstValue("assertionDetailsModeIdentifier", in: json) as? String else { return .some(nil) }
        var mode = known[id] ?? Mode(id: id, name: "Focus", symbol: "moon.fill", tint: .systemIndigo)
        mode.id = id
        if let config = try? Data(contentsOf: dir.appendingPathComponent("ModeConfigurations.json")),
           let configJSON = try? JSONSerialization.jsonObject(with: config),
           let m = modeDictionary(id, in: configJSON) {
            if let name = m["name"] as? String, !name.isEmpty { mode.name = name }
            if let symbol = m["symbolImageName"] as? String, !symbol.isEmpty { mode.symbol = symbol }
            if let tint = (m["tintColorName"] as? String).flatMap({ tints[$0] }) { mode.tint = tint }
        }
        return .some(mode)
    }

    nonisolated static let sleepID = "com.apple.sleep.sleep-mode"

    nonisolated static let known: [String: Mode] = [
        "com.apple.donotdisturb.mode.default": Mode(id: "", name: "Do Not Disturb", symbol: "moon.fill", tint: .systemIndigo),
        "com.apple.focus.work": Mode(id: "", name: "Work", symbol: "briefcase.fill", tint: .systemTeal),
        sleepID: Mode(id: "", name: "Sleep", symbol: "bed.double.fill", tint: .systemMint),
        "com.apple.focus.personal-time": Mode(id: "", name: "Personal", symbol: "person.fill", tint: .systemPurple),
        "com.apple.donotdisturb.mode.driving": Mode(id: "", name: "Driving", symbol: "car.fill", tint: .systemOrange),
        "com.apple.focus.fitness": Mode(id: "", name: "Fitness", symbol: "figure.run", tint: .systemGreen),
        "com.apple.focus.reading": Mode(id: "", name: "Reading", symbol: "book.fill", tint: .systemOrange),
        "com.apple.focus.gaming": Mode(id: "", name: "Gaming", symbol: "gamecontroller.fill", tint: .systemBlue),
        "com.apple.focus.mindfulness": Mode(id: "", name: "Mindfulness", symbol: "brain.head.profile", tint: .systemCyan),
    ]

    nonisolated static let tints: [String: NSColor] = [
        "systemIndigoColor": .systemIndigo, "systemTealColor": .systemTeal, "systemMintColor": .systemMint,
        "systemPurpleColor": .systemPurple, "systemOrangeColor": .systemOrange, "systemGreenColor": .systemGreen,
        "systemBlueColor": .systemBlue, "systemPinkColor": .systemPink, "systemRedColor": .systemRed,
        "systemYellowColor": .systemYellow, "systemCyanColor": .systemCyan, "systemBrownColor": .systemBrown,
        "systemGrayColor": .systemGray,
    ]

    /// Depth-first search for the first value stored under `key`.
    nonisolated static func firstValue(_ key: String, in json: Any) -> Any? {
        if let dict = json as? [String: Any] {
            if let v = dict[key] { return v }
            for v in dict.values { if let found = firstValue(key, in: v) { return found } }
        } else if let array = json as? [Any] {
            for v in array { if let found = firstValue(key, in: v) { return found } }
        }
        return nil
    }

    /// The `mode` dictionary whose `modeIdentifier` is `id`.
    nonisolated static func modeDictionary(_ id: String, in json: Any) -> [String: Any]? {
        if let dict = json as? [String: Any] {
            if dict["modeIdentifier"] as? String == id { return dict }
            for v in dict.values { if let found = modeDictionary(id, in: v) { return found } }
        } else if let array = json as? [Any] {
            for v in array { if let found = modeDictionary(id, in: v) { return found } }
        }
        return nil
    }
}

@MainActor
enum FocusItems {
    static let activityID = "system.focus"

    static func changed(_ mode: FocusMonitor.Mode, on: Bool) -> IslandItem {
        let tint = Color(nsColor: mode.tint)
        return IslandItem(id: "system.focusChange", kind: .notification) {
            Group {
                if on {
                    BouncingSymbol(name: DeviceSymbol.resolve(mode.symbol, fallback: "moon.fill"), color: tint, size: 16)
                } else {
                    Image(systemName: DeviceSymbol.resolve(mode.symbol, fallback: "moon.fill")).islandSymbol(16).foregroundStyle(Palette.muted)
                }
            }
            .padding(.leading, 12)
        } trailing: {
            WingText(FocusL10n.text(on ? "On" : "Off"), color: on ? tint : Palette.muted)
        }
        .peek(always: true) { PeekLabel(mode.title) }
    }

    static func activity(_ mode: FocusMonitor.Mode) -> IslandItem {
        let tint = Color(nsColor: mode.tint)
        return IslandItem(id: activityID, kind: .liveActivity, priority: 1) {
            Image(systemName: DeviceSymbol.resolve(mode.symbol, fallback: "moon.fill")).islandSymbol(15).foregroundStyle(tint).padding(.leading, 12)
        } trailing: {
            Circle().fill(tint).frame(width: 7, height: 7).padding(.trailing, 15)
        }
        .peek(onHover: true) {
            // Long forms ("Mode de concentration Travail" on a pill) give way to the bare name.
            ViewThatFits(in: .horizontal) {
                if mode.id != FocusMonitor.genericID { PeekLabel(String(format: FocusL10n.text("%@ Focus"), mode.title)) }
                PeekLabel(mode.title)
            }
        }
    }
}

/// Start of localization: Focus strings in Italian, German, French and Spanish, worded as
/// in macOS's own tables (DoNotDisturb, FocusSettingsUI and Control Center's Focus module).
/// The app bundle has no .lproj folders (scripts/build.sh), so the table lives here,
/// keyed by the English text; anything missing stays English.
enum FocusL10n {
    static let language = language(for: Locale.preferredLanguages)

    /// The first preferred language Isola has strings for, with the system's own fallbacks.
    static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "it", "de", "fr", "es"], forPreferences: preferences).first ?? "en"
    }

    static func text(_ english: String, language: String = FocusL10n.language) -> String {
        table[english]?[language] ?? english
    }

    private static let table: [String: [String: String]] = [
        "Focus": ["it": "Full immersion", "de": "Fokus", "fr": "Concentration", "es": "Concentración"],
        "%@ Focus": ["it": "Full immersion - %@", "de": "Fokus „%@“", "fr": "Mode de concentration %@", "es": "Modo “%@”"],
        // Control Center's short On/Off (its Spanish is Activado, too wide for the wing: Focus settings' Sí/No).
        "On": ["it": "Sì", "de": "Ein", "fr": "Oui", "es": "Sí"],
        "Off": ["it": "No", "de": "Aus", "fr": "Non", "es": "No"],
        "Do Not Disturb": ["it": "Non disturbare", "de": "Nicht stören", "fr": "Ne pas déranger", "es": "No molestar"],
        "Work": ["it": "Lavoro", "de": "Arbeiten", "fr": "Travail", "es": "Trabajo"],
        "Sleep": ["it": "Sonno", "de": "Schlafen", "fr": "Repos", "es": "Descanso"],
        "Personal": ["it": "Personale", "de": "Zeit für mich", "fr": "Temps pour soi", "es": "Tiempo libre"],
        "Driving": ["it": "Guida", "de": "Fahren", "fr": "Conduite", "es": "Conducción"],
        "Fitness": ["it": "Fitness", "de": "Fitness", "fr": "Sport", "es": "Ejercicio"],
        "Reading": ["it": "Lettura", "de": "Lesen", "fr": "Lecture", "es": "Lectura"],
        "Gaming": ["it": "Videogiochi", "de": "Spielen", "fr": "Jeu vidéo", "es": "Juego"],
        "Mindfulness": ["it": "Mindfulness", "de": "Achtsamkeit", "fr": "Pleine conscience", "es": "Mindfulness"],
    ]
}
