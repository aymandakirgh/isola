import CoreLocation
import MapKit

/// How the user gets to events, for time-to-leave alerts.
enum TravelMode: String, CaseIterable, Identifiable {
    case driving, walking, transit
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        }
    }
    /// As in "25m by car".
    var phrase: String {
        switch self {
        case .driving: "by car"
        case .walking: "on foot"
        case .transit: "by transit"
        }
    }
    fileprivate var transport: MKDirectionsTransportType {
        switch self {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
    }
}

/// Travel time to events with a location, from Apple Maps ETAs. Only runs when location
/// access is already granted (it never asks); ETAs are cached per event and travel mode
/// and refreshed at most every few minutes.
@MainActor
final class TravelTime {
    static let shared = TravelTime()
    private static let refresh: TimeInterval = 5 * 60
    // ponytail: ETAs only for events starting within 4 h, so a longer trip alerts late; widen if that matters.
    private static let horizon: TimeInterval = 4 * 3600
    private var etas: [String: (seconds: TimeInterval?, at: Date)] = [:]
    private var places: [String: CLLocation] = [:]
    private var pending: Set<String> = []

    /// The cached travel time to `e` (nil while unknown), refreshed in the background when stale.
    /// `place` is the calendar's own coordinate for the event, if any; otherwise its location is geocoded.
    func estimate(for e: CalendarEvent, place: CLLocation?, now: Date) -> TimeInterval? {
        guard Weather.shared.locationAuthorized, let address = e.location else { return nil }
        let mode = CalendarPreferences.shared.travelMode
        let key = "\(e.id)|\(mode.rawValue)"
        let cached = etas[key]
        let stale = cached.map { now.timeIntervalSince($0.at) >= Self.refresh } ?? true
        if stale, e.start.timeIntervalSince(now) < Self.horizon, pending.insert(key).inserted {
            Task { await update(key, address: address, place: place, mode: mode) }
        }
        return cached?.seconds
    }

    /// `isolactl cal.state`: the cached ETAs.
    var report: String {
        etas.map { "\($0.key)=\($0.value.seconds.map { "\(Int($0 / 60))m" } ?? "none")" }.sorted().joined(separator: " ")
    }

    private func update(_ key: String, address: String, place: CLLocation?, mode: TravelMode) async {
        defer { pending.remove(key) }
        var seconds: TimeInterval?
        if let destination = await locate(address, known: place) {
            let request = MKDirections.Request()
            request.source = Weather.shared.lastLocation.map { MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate)) } ?? .forCurrentLocation()
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
            request.transportType = mode.transport
            seconds = try? await MKDirections(request: request).calculateETA().expectedTravelTime
        }
        etas[key] = (seconds, Date())
    }

    private func locate(_ address: String, known: CLLocation?) async -> CLLocation? {
        if let place = known ?? places[address] { return place }
        let found = try? await CLGeocoder().geocodeAddressString(address).first?.location
        places[address] = found
        return found
    }

    /// Time to leave once `now` passes start − travel − buffer (or start − `fallback` without
    /// a travel time), until the event starts.
    nonisolated static func isTimeToLeave(now: Date, start: Date, travel: TimeInterval?, buffer: TimeInterval, fallback: TimeInterval) -> Bool {
        now < start && now >= start.addingTimeInterval(-(travel.map { $0 + buffer } ?? fallback))
    }

    /// Runs with the gallery (`Isola --gallery`): the leave-time math.
    static func selfCheck() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func leave(_ minutesBefore: Double, travel: Double?) -> Bool {
            isTimeToLeave(now: start.addingTimeInterval(-minutesBefore * 60), start: start, travel: travel.map { $0 * 60 }, buffer: 5 * 60, fallback: 15 * 60)
        }
        precondition(!leave(31, travel: 25) && leave(30, travel: 25) && leave(10, travel: 25), "25 min trip + 5 min buffer")
        precondition(!leave(16, travel: nil) && leave(15, travel: nil), "no travel time: the fixed 15 min")
        precondition(leave(1, travel: 90) && !leave(0, travel: 90), "late is still time to leave, until the start")
    }
}
