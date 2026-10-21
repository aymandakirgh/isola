import CoreLocation
import Foundation

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

    private var locationAuthorized: Bool {
        [.authorizedAlways, .authorized].contains(location.authorizationStatus)
    }

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
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code,precipitation,is_day&hourly=precipitation_probability&forecast_hours=6&timezone=auto")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let forecast = try? JSONDecoder().decode(Forecast.self, from: data) else { return }
        let w = WeatherState.shared
        let code = WeatherCode.describe(forecast.current.weather_code, isDay: forecast.current.is_day == 1)
        w.temperature = forecast.current.temperature_2m
        w.symbol = code.symbol
        w.condition = code.text
        // Chance of rain over the next few hours (the "precipitation details" line).
        let chances = (forecast.hourly?.precipitation_probability ?? []).compactMap { $0 }
        w.precipitationChance = chances.max().map { Double($0) / 100 }
        w.place = place
        w.available = true
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
    struct Hourly: Decodable { let precipitation_probability: [Int?]? }
    let current: Current
    let hourly: Hourly?
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

    /// Runs with the gallery (`Isola --gallery`): fails loudly if the mapping regresses.
    static func selfCheck() {
        assert(describe(0, isDay: true).symbol == "sun.max.fill")
        assert(describe(0, isDay: false).symbol == "moon.stars.fill")
        assert(describe(65, isDay: true).text == "Heavy rain")
        assert(describe(95, isDay: true).symbol == "cloud.bolt.rain.fill")
        assert(describe(1234, isDay: true).text == "Cloudy")
    }
}
