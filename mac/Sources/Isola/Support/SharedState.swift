import AppKit
import Observation

// Data that several modules show. Producers (Media, System, Calendar) write here;
// consumers (Lock Screen widgets, menu bar, settings) read. Producers own the logic.

@MainActor @Observable
final class NowPlayingState {
    static let shared = NowPlayingState()
    var title = ""
    var artist = ""
    var album = ""
    var artwork: NSImage?
    /// Two dominant artwork colours (top → bottom), used for the spectrogram gradient.
    var colors: [NSColor] = [NSColor(red: 0.83, green: 0.62, blue: 0.63, alpha: 1), NSColor(red: 0.42, green: 0.35, blue: 0.42, alpha: 1)]
    var isPlaying = false
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    /// When `elapsed` was sampled, for live interpolation.
    var elapsedAt = Date()
    /// Last local seek or speed change; snapshots that arrive just after it may still carry the old values.
    var adjustedAt = Date.distantPast
    var rate: Double = 1
    var shuffle = false
    var repeatMode = 0  // 0 off, 1 one, 2 all
    var sourceBundleID: String?
    var isExplicit = false
    /// The source takes a like (Music favourite, MediaRemote LikeTrack).
    var canLike = false
    var liked = false
    /// Apple Music AutoMix is crossfading into the next track.
    var inTransition = false
    /// "Lossless", "Hi-Res Lossless" or "Dolby Atmos" when the player reports its stream format.
    var audioFormat: String?
    /// A link is known, or the player can be asked for one (Spotify, browser tabs).
    var canCopyLink = false
    /// A podcast episode in a player that also plays music (Spotify).
    var isEpisode = false
    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }
    var isPodcast: Bool { isEpisode || sourceBundleID == "com.apple.podcasts" }

    /// Commands are wired by the Media module.
    var commands = MediaCommands()

    func currentElapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return elapsed }
        return min(duration > 0 ? duration : .infinity, elapsed + date.timeIntervalSince(elapsedAt) * rate)
    }

    /// Seek and show the new position at once, before the source confirms it.
    func seek(to time: TimeInterval) {
        elapsed = max(0, duration > 0 ? min(time, duration) : time)
        elapsedAt = Date()
        adjustedAt = elapsedAt
        commands.seek(elapsed)
    }

    /// Change speed; the label and the interpolated position follow before the source confirms.
    func setRate(_ value: Double) {
        elapsed = currentElapsed()
        elapsedAt = Date()
        adjustedAt = elapsedAt
        rate = value
        commands.setRate(value)
    }
}

struct MediaCommands {
    var togglePlay: () -> Void = {}
    var next: () -> Void = {}
    var previous: () -> Void = {}
    var seek: (TimeInterval) -> Void = { _ in }
    var toggleShuffle: () -> Void = {}
    var cycleRepeat: () -> Void = {}
    var setRate: (Double) -> Void = { _ in }
    /// Brings the player forward (for a browser, the tab that plays).
    var openSource: () -> Void = {}
    var toggleLike: () -> Void = {}
    /// Puts the track's link on the pasteboard, asking the player when needed; reports success.
    var copyLink: (@escaping (Bool) -> Void) -> Void = { $0(false) }
}

@MainActor @Observable
final class PowerState {
    static let shared = PowerState()
    var hasBattery = false
    var level: Double = 1  // 0...1
    var charging = false
    var pluggedIn = false
    var lowPowerMode = false
    /// Minutes, nil when unknown.
    var timeToFull: Int?
    var timeToEmpty: Int?
    /// The connected power adapter's rating, when it reports one.
    var adapterWatts: Int?
}

struct ConnectedDevice: Identifiable, Equatable {
    var id: String  // address
    var name: String
    /// SF Symbol for the device (airpodspro, headphones, hifispeaker, ...).
    var symbol: String
    var battery: Double?  // 0...1
    var caseBattery: Double?
}

@MainActor @Observable
final class DevicesState {
    static let shared = DevicesState()
    var devices: [ConnectedDevice] = []
}

@MainActor @Observable
final class FocusState {
    static let shared = FocusState()
    var active = false
    var name = ""
    var symbol = "moon.fill"
    var tint: NSColor = .systemIndigo
}

@MainActor @Observable
final class WeatherState {
    static let shared = WeatherState()
    var available = false
    var temperature: Double = 0  // °C
    var useFahrenheit = Locale.current.measurementSystem == .us
    var symbol = "sun.max.fill"
    var condition = ""
    var precipitationChance: Double?  // 0...1
    var precipitationDetail: String?  // "Rain at 18:00 · 60%"; nil when the next hours stay dry
    var place = ""
    var displayTemperature: String {
        let t = useFahrenheit ? temperature * 9 / 5 + 32 : temperature
        return "\(Int(t.rounded()))°"
    }
}

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendarColor: NSColor
    var location: String?
    var isAllDay = false
}

@MainActor @Observable
final class CalendarState {
    static let shared = CalendarState()
    var authorized = false
    var today: [CalendarEvent] = []
    var next: CalendarEvent? { today.first { $0.end > Date() && !$0.isAllDay } }
}
