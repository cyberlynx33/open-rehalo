import Foundation
import CoreLocation
import MapKit

/// Place search for the Map tab's search sheet: Apple's suggestions as you type
/// (`MKLocalSearchCompleter`), resolved to a `Destination` on tap, plus the last destinations used.
/// Long-press pins get their name from reverse geocoding (`name(at:)`).
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    /// A destination used before (persisted, newest first).
    struct Recent: Codable, Identifiable, Equatable {
        var name: String
        var subtitle: String?
        var latitude: Double
        var longitude: Double
        var id: String { "\(name)|\(latitude)|\(longitude)" }

        var destination: Destination {
            Destination(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        name: name, subtitle: subtitle)
        }
    }

    @Published var query = "" {
        didSet {
            let q = query.trimmingCharacters(in: .whitespaces)
            if q.isEmpty { completer.cancel(); suggestions = [] } else { completer.queryFragment = q }
        }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var recents: [Recent] = []

    private let completer = MKLocalSearchCompleter()
    private static let recentsKey = "sh2.map.recentDestinations"
    private static let maxRecents = 8

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        recents = Self.loadRecents()
    }

    /// Bias suggestions towards what the map shows.
    func setRegion(_ region: MKCoordinateRegion) { completer.region = region }

    /// A suggestion → its place (coordinate + name).
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Destination {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else { throw RouteError.noRoute }
        let subtitle = completion.subtitle.isEmpty ? nil : completion.subtitle
        return Destination(coordinate: item.placemark.coordinate,
                           name: item.name ?? completion.title, subtitle: subtitle)
    }

    func remember(_ d: Destination) {
        let r = Recent(name: d.name, subtitle: d.subtitle,
                       latitude: d.coordinate.latitude, longitude: d.coordinate.longitude)
        recents = Array(([r] + recents.filter { $0.id != r.id }).prefix(Self.maxRecents))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    private static func loadRecents() -> [Recent] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let list = try? JSONDecoder().decode([Recent].self, from: data) else { return [] }
        return list
    }

    /// Street + number (or the place's name) and the town, for a pin. Nil without network.
    static func name(at coordinate: CLLocationCoordinate2D) async -> (name: String, subtitle: String?)? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: ", ")
        let name = street.isEmpty ? (p.name ?? p.locality) : street
        guard let name else { return nil }
        return (name, p.locality == name ? nil : p.locality)
    }

    // MARK: - MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
