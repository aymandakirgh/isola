import AppKit
import CoreLocation

/// Current conditions from Open-Meteo (no API key) → `WeatherState`. Uses Core Location
/// only when already authorised (or after "Use current location"), else the city set in settings.
@MainActor
final class Weather: NSObject, CLLocationManagerDelegate {
    static let shared = Weather()
    private let location = CLLocationManager()
    private var timer: Timer?

    func start() {
        location.delegate = self
        Self.applyUnit()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Weather.shared.refresh() }
        }
        refresh()
    }

    var locationAuthorized: Bool {
        [.authorizedAlways, .authorized].contains(location.authorizationStatus)
    }

    /// Reading it never asks.
    var locationUndecided: Bool { location.authorizationStatus == .notDetermined }

    /// The last fix while it's recent (weather refreshes take one every 30 min): where travel times start.
    var lastLocation: CLLocation? { location.location.flatMap { $0.timestamp.timeIntervalSinceNow > -45 * 60 ? $0 : nil } }

    func refresh() {
        let prefs = CalendarPreferences.shared
        guard prefs.weather else { return WeatherState.shared.available = false }
        if locationAuthorized {
            location.requestLocation()
        } else if let lat = prefs.weatherLatitude, let lon = prefs.weatherLongitude {
            Task { await fetch(latitude: lat, longitude: lon, place: prefs.weatherCity) }
        }
    }

    /// Settings: "Use current location" (the only place that asks for permission).
    func useCurrentLocation() {
        if locationAuthorized { location.requestLocation() } else { location.requestWhenInUseAuthorization() }
    }

    /// Settings: geocode a city name, remember it, then fetch.
    func setCity(_ name: String) async {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty,
              let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let hit = (try? JSONDecoder().decode(GeocodeResponse.self, from: data))?.results?.first
        else { return }
        let prefs = CalendarPreferences.shared
        prefs.weatherCity = hit.name
        prefs.weatherLatitude = hit.latitude
        prefs.weatherLongitude = hit.longitude
        await fetch(latitude: hit.latitude, longitude: hit.longitude, place: hit.name)
    }

    func fetch(latitude: Double, longitude: Double, place: String) async {
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code,precipitation,is_day&hourly=precipitation_probability,weather_code&forecast_hours=12&daily=sunrise,sunset&timezone=auto&timeformat=unixtime")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let forecast = try? JSONDecoder().decode(Forecast.self, from: data) else { return }
        let w = WeatherState.shared
        let code = WeatherCode.describe(forecast.current.weather_code, isDay: forecast.current.is_day == 1)
        w.temperature = forecast.current.temperature_2m
        w.symbol = code.symbol
        w.condition = code.text
        // Chance of rain over the next hours, and when and what the first rain is.
        let chances = (forecast.hourly?.precipitation_probability ?? []).compactMap { $0 }
        w.precipitationChance = chances.max().map { Double($0) / 100 }
        w.precipitationDetail = Self.rainOutlook(forecast, now: Date())
        w.sunrise = Self.dates(forecast.daily?.sunrise)
        w.sunset = Self.dates(forecast.daily?.sunset)
        w.timeZone = forecast.zone
        w.place = place
        w.available = true
    }

    /// The first wet hour ahead (a 30 % chance, or a wet code where the chance is missing):
    /// "Rain at 18:00 · 60%", "Snow from 07:00 · 80%" for a run of wet hours, "Showers now · 40%".
    /// nil when the forecast stays dry. Times are the forecast place's own.
    private static func rainOutlook(_ f: Forecast, now: Date, locale: Locale = .autoupdatingCurrent) -> String? {
        struct Hour { let start: Date; let code: Int?; let chance: Int? }
        let times = f.hourly?.time ?? [], codes = f.hourly?.weather_code ?? [], chances = f.hourly?.precipitation_probability ?? []
        let hours = times.indices.map { i in
            Hour(start: Date(timeIntervalSince1970: TimeInterval(times[i])), code: i < codes.count ? codes[i] : nil, chance: i < chances.count ? chances[i] : nil)
        }
        .filter { $0.start.addingTimeInterval(3600) > now }
        func wet(_ h: Hour) -> Bool { h.chance.map { $0 >= 30 } ?? (h.code.flatMap(WeatherCode.precipitation) != nil) }
        guard let first = hours.firstIndex(where: wet) else { return nil }
        let run = hours[first...].prefix(while: wet)
        let kind = run.lazy.compactMap { $0.code.flatMap(WeatherCode.precipitation) }.first ?? "Rain"
        let start = hours[first].start
        let time = start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: f.zone))
        let when = start <= now ? "now" : run.count > 1 ? "from \(time)" : "at \(time)"
        return "\(kind) \(when)" + (run.compactMap(\.chance).max().map { " · \($0)%" } ?? "")
    }

    /// Daily unix times; a day without one (polar day or night) is left out.
    private static func dates(_ times: [Int?]?) -> [Date] {
        (times ?? []).compactMap { $0.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    }

    /// Runs with the gallery (`Isola --gallery`): the rain outlook from canned Open-Meteo JSON.
    static func selfCheck() {
        func outlook(_ chances: String, _ codes: String) -> String? {
            // Hourly 14:00–21:00 in Rome (CEST), read at 14:30.
            let json = #"{"timezone":"Europe/Rome","current":{"temperature_2m":21.4,"weather_code":2,"is_day":1},"hourly":{"time":[1792584000,1792587600,1792591200,1792594800,1792598400,1792602000,1792605600,1792609200],"precipitation_probability":\#(chances),"weather_code":\#(codes)}}"#
            let forecast = try! JSONDecoder().decode(Forecast.self, from: Data(json.utf8))
            return rainOutlook(forecast, now: Date(timeIntervalSince1970: 1_792_584_000 + 1800), locale: Locale(identifier: "en_GB"))
        }
        precondition(outlook("[0,10,20,0,60,0,0,0]", "[2,2,3,3,61,3,2,2]") == "Rain at 18:00 · 60%")
        precondition(outlook("[0,0,0,40,80,70,0,0]", "[3,3,3,71,73,71,3,3]") == "Snow from 17:00 · 80%")
        precondition(outlook("[50,20,0,0,0,0,0,0]", "[80,3,3,3,3,3,3,3]") == "Showers now · 50%")
        precondition(outlook("[null,null,null,null,null,null,null,null]", "[2,2,95,2,2,2,2,2]") == "Thunderstorm at 16:00")
        precondition(outlook("[0,10,20,10,0,0,0,0]", "[2,2,3,3,2,2,2,2]") == nil)
        // Sunrise and sunset come as unix times per day; a missing one (polar night) is skipped.
        let daily = #"{"current":{"temperature_2m":4,"weather_code":0,"is_day":0},"daily":{"time":[1792533600,1792620000],"sunrise":[1792561200,null],"sunset":[1792600140,1792686480]}}"#
        let forecast = try! JSONDecoder().decode(Forecast.self, from: Data(daily.utf8)), sun = forecast.daily
        precondition(dates(sun?.sunrise) == [Date(timeIntervalSince1970: 1_792_561_200)] && dates(sun?.sunset).count == 2, "daily sunrise and sunset")
        // They read in the place's time zone, like the rain outlook; an answer without one reads in this Mac's.
        let tokyo = try! JSONDecoder().decode(Forecast.self, from: Data(daily.replacingOccurrences(of: #"{"current""#, with: #"{"timezone":"Asia/Tokyo","current""#).utf8))
        precondition(tokyo.zone.identifier == "Asia/Tokyo" && forecast.zone == .current, "the forecast place's time zone")
    }

    static func applyUnit() {
        let unit = CalendarPreferences.shared.weatherUnit
        WeatherState.shared.useFahrenheit = unit == "auto" ? Locale.current.measurementSystem == .us : unit == "f"
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in
            let place = CalendarPreferences.shared.weatherCity.isEmpty ? "Current location" : CalendarPreferences.shared.weatherCity
            await Weather.shared.fetch(latitude: c.latitude, longitude: c.longitude, place: place)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in Weather.shared.refresh() }
    }
}

/// Location in a `PermissionRow` (the weather, and travel times for time to leave). Asked for
/// the way "Use Current Location" asks.
struct LocationPermission: PermissionKind {
    var title: String { "Location access" }
    var detail: String { "Uses your location for the weather and time to leave." }

    @MainActor func status() -> PermissionStatus {
        Weather.shared.locationAuthorized ? .granted : Weather.shared.locationUndecided ? .notDetermined : .denied
    }

    @MainActor func request(_ done: @escaping () -> Void) {
        Weather.shared.useCurrentLocation()
        done()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
    }
}

private struct GeocodeResponse: Decodable {
    struct Place: Decodable { let name: String; let latitude: Double; let longitude: Double }
    let results: [Place]?
}

private struct Forecast: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int
    }
    /// Parallel arrays, one entry per hour from the current one (`time` in unix seconds).
    struct Hourly: Decodable {
        let time: [Int]?
        let precipitation_probability: [Int?]?
        let weather_code: [Int?]?
    }
    /// One entry per day from today, in unix seconds.
    struct Daily: Decodable {
        let sunrise: [Int?]?
        let sunset: [Int?]?
    }
    let timezone: String?
    let current: Current
    let hourly: Hourly?
    let daily: Daily?

    /// The place's time zone (`timezone=auto`), this Mac's when the answer has none.
    var zone: TimeZone { timezone.flatMap(TimeZone.init(identifier:)) ?? .current }
}

/// WMO weather interpretation codes → SF Symbol + short condition.
enum WeatherCode {
    static func describe(_ code: Int, isDay: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0: (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1: (isDay ? "sun.max.fill" : "moon.stars.fill", "Mostly clear")
        case 2: (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51, 53, 55, 56, 57: ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 66: ("cloud.rain.fill", code == 61 ? "Light rain" : "Rain")
        case 65, 67: ("cloud.heavyrain.fill", "Heavy rain")
        case 71, 73, 75, 77, 85, 86: ("cloud.snow.fill", "Snow")
        case 80, 81, 82: (isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Showers")
        case 95, 96, 99: ("cloud.bolt.rain.fill", "Thunderstorm")
        default: ("cloud.fill", "Cloudy")
        }
    }

    /// What falls, for wet codes ("Snow from 07:00"); nil for dry ones.
    static func precipitation(_ code: Int) -> String? {
        switch code {
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...77, 85, 86: "Snow"
        case 80...82: "Showers"
        case 95...99: "Thunderstorm"
        default: nil
        }
    }

    /// Runs with the gallery (`Isola --gallery`): fails loudly if the mapping regresses.
    static func selfCheck() {
        assert(describe(0, isDay: true).symbol == "sun.max.fill")
        assert(describe(0, isDay: false).symbol == "moon.stars.fill")
        assert(describe(65, isDay: true).text == "Heavy rain")
        assert(describe(95, isDay: true).symbol == "cloud.bolt.rain.fill")
        assert(describe(1234, isDay: true).text == "Cloudy")
    }
}
