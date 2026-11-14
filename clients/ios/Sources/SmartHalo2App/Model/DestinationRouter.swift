import Foundation
import CoreLocation
import MapKit
import SH2Protocol

/// A place picked on the Map tab: a search result or a long-press pin.
struct Destination: Identifiable, Equatable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D
    var name: String
    var subtitle: String?

    init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D, name: String, subtitle: String? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.name = name
        self.subtitle = subtitle
    }

    static func == (a: Destination, b: Destination) -> Bool {
        a.id == b.id && a.name == b.name && a.subtitle == b.subtitle
            && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

/// How the rider wants to get there: BRouter's bike profiles (docs/APP_SPEC.md M17). MapKit has one
/// bike profile and no notion of rider, so without BRouter each kind asks it for the closest thing it
/// has and the rider is told (`AppleRouteProvider`).
enum RouteProfile: String, CaseIterable, Identifiable {
    /// Bike lanes and quiet streets: BRouter `trekking`, Apple's bike routes.
    case city
    /// Tarmac: BRouter `fastbike`; Apple's car routes without motorways or tolls, which is not a bike
    /// route and nothing keeps off busy roads.
    case road
    /// Tracks and unpaved roads: BRouter `gravel`; Apple has none, so its bike routes.
    case gravel
    /// Trails: BRouter `mtb`; Apple has none, so its walking routes.
    case mtb

    var id: String { rawValue }

    /// A stored value, including the `trails` profile of earlier versions (walking routes), now MTB.
    init?(stored raw: String) {
        if raw == "trails" { self = .mtb; return }
        self.init(rawValue: raw)
    }

    /// The BRouter profile (`misc/profiles2/<name>.brf`).
    var brouterProfile: String {
        switch self {
        case .city: return "trekking"
        case .road: return "fastbike"
        case .gravel: return "gravel"
        case .mtb: return "mtb"
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .city: return "City"
        case .road: return "Road"
        case .gravel: return "Gravel"
        case .mtb: return "MTB"
        }
    }

    var systemImage: String {
        switch self {
        case .city: return "bicycle"
        case .road: return "road.lanes"
        case .gravel: return "mountain.2"
        case .mtb: return "figure.outdoor.cycle"
        }
    }
}

/// Who computed a route: the pill says so, and a saved one keeps it as its source.
enum RouteProviderKind: String, Sendable {
    case appleMaps, brouter

    var label: String {
        switch self {
        case .appleMaps: return "Apple Maps"
        case .brouter: return "BRouter"
        }
    }

    var routeSource: RouteSource {
        switch self {
        case .appleMaps: return .appleMaps
        case .brouter: return .brouter
        }
    }
}

/// A route to a destination, ready for the ring guidance.
struct RoutedDestination {
    /// What the route is for, which isn't always what was asked.
    enum Travel {
        case bike, car, foot

        var label: String {
            switch self {
            case .bike: return String(localized: "by bike")
            case .car: return String(localized: "by road")
            case .foot: return String(localized: "on foot")
            }
        }
    }

    let route: GPXRoute
    /// Where each manoeuvre is + its text shortened for the ring's OLED.
    let instructions: [(location: NavLocation, text: String)]
    /// The service's own steps: the turns of the ride, typed when the service types them (BRouter).
    let steps: [RoutedStep]
    let expectedTravelTime: TimeInterval
    let travel: Travel
    /// What the rider should know before leaving, most important first.
    var notices: [String]
    let provider: RouteProviderKind
}

/// A routing service: Apple's `MKDirections` or a BRouter server (docs/APP_SPEC.md M17). The
/// `RoutingService` picks one and falls back to Apple.
protocol RouteProvider: Sendable {
    var kind: RouteProviderKind { get }

    /// Routes from `origin` to `destination` through `stops`, the best first, at most
    /// `RoutingService.maxOptions`. `id` keeps a stable route id (the destination's, or a lead-in's).
    func routes(to destination: Destination, from origin: CLLocationCoordinate2D, via stops: [CLLocationCoordinate2D],
                profile: RouteProfile, id: UUID) async throws -> [RoutedDestination]
}

enum RouteError: LocalizedError {
    case noRoute
    /// Apple's bike routes need a build with Xcode 26 (`MKDirectionsTransportType.cycling`).
    case noBikeRoutes
    case noPosition
    case badURL

    var errorDescription: String? {
        switch self {
        case .noRoute: return String(localized: "No route found to this place.")
        case .noBikeRoutes: return String(localized: "This build has no Apple bike routes.")
        case .noPosition: return String(localized: "Waiting for your position to route from.")
        case .badURL: return String(localized: "The BRouter URL in Settings isn't valid.")
        }
    }
}

/// Routes with MapKit (`MKDirections`), no server of our own, in the rider's `RouteProfile`. Needs a
/// network connection; once computed, guidance works offline. Stops are routed leg by leg (MapKit
/// has no via points) and the legs chained; with stops there are no alternatives.
struct AppleRouteProvider: RouteProvider {
    var kind: RouteProviderKind { .appleMaps }

    func routes(to destination: Destination, from origin: CLLocationCoordinate2D, via stops: [CLLocationCoordinate2D],
                profile: RouteProfile, id: UUID) async throws -> [RoutedDestination] {
        try await DestinationRouter.routes(to: destination, from: origin, via: stops, profile: profile, id: id)
    }
}

/// The MapKit side of `AppleRouteProvider`. `origin` nil = the current location (MapKit's own).
enum DestinationRouter {
    /// Routes from `origin` to `destination`, Apple's best first. `id` keeps a stable route id.
    static func routes(to destination: Destination, from origin: CLLocationCoordinate2D? = nil,
                       via stops: [CLLocationCoordinate2D] = [], profile: RouteProfile,
                       id: UUID = UUID()) async throws -> [RoutedDestination] {
        let transport = try transport(for: profile)
        guard !stops.isEmpty else {
            return try await calculate(destination, origin, id: id, transport: transport, note: note(for: profile))
        }
        // Leg by leg: the best route of each, chained into one.
        var legs: [RoutedDestination] = []
        var from = origin
        for (i, c) in (stops + [destination.coordinate]).enumerated() {
            let last = i == stops.count
            let place = last ? destination : Destination(coordinate: c, name: String(localized: "Stop \(i + 1)"))
            guard let best = try await calculate(place, from, id: id, transport: transport, note: nil).first else {
                throw RouteError.noRoute
            }
            legs.append(best)
            from = c
        }
        return [chained(legs, to: destination, id: id, note: note(for: profile))]
    }

    /// Apple's best route, where the rider doesn't choose (a lead-in).
    static func route(to destination: Destination, from origin: CLLocationCoordinate2D? = nil,
                      profile: RouteProfile, id: UUID = UUID()) async throws -> RoutedDestination {
        guard let best = try await routes(to: destination, from: origin, profile: profile, id: id).first else {
            throw RouteError.noRoute
        }
        return best
    }

    /// What MapKit is asked for each profile. City used to fall back to a walking route silently when
    /// Apple had no bike route; now the error shows, and Trails became MTB.
    static func transport(for profile: RouteProfile) throws -> MKDirectionsTransportType {
        switch profile {
        case .city, .gravel:
            guard let bike = bikeTransport else { throw RouteError.noBikeRoutes }
            return bike
        case .road:
            return .automobile
        case .mtb:
            return .walking
        }
    }

    /// Told to the rider when Apple stands in for a profile it doesn't have.
    static func note(for profile: RouteProfile) -> String? {
        switch profile {
        case .city, .road: return nil
        case .gravel: return String(localized: "Calculated with Apple Maps: no gravel profile, using City.")
        case .mtb: return String(localized: "Calculated with Apple Maps: no MTB profile, using walking routes.")
        }
    }

    private static func calculate(_ destination: Destination, _ origin: CLLocationCoordinate2D?, id: UUID,
                                  transport: MKDirectionsTransportType, note: String?) async throws -> [RoutedDestination] {
        let request = MKDirections.Request()
        request.source = origin.map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) } ?? .forCurrentLocation()
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.requestsAlternateRoutes = true
        request.transportType = transport
        if transport == .automobile {
            request.highwayPreference = .avoid
            request.tollPreference = .avoid
        }
        let response = try await MKDirections(request: request).calculate()
        // `.avoid` is only a preference: motorways are the last resort.
        let clear = response.routes.filter { !$0.hasHighways }
        let routes = transport == .automobile && !clear.isEmpty ? clear : response.routes
        let options = routes.prefix(RoutingService.maxOptions).compactMap { routed($0, to: destination, id: id, note: note) }
        guard !options.isEmpty else { throw RouteError.noRoute }
        return options
    }

    private static func routed(_ r: MKRoute, to destination: Destination, id: UUID, note: String?) -> RoutedDestination? {
        let points = r.polyline.coordinates
        guard points.count >= 2 else { return nil }
        let route = GPXRoute(id: id, name: destination.name, points: points)
        let travel: RoutedDestination.Travel = r.transportType == .walking ? .foot
            : r.transportType == .automobile ? .car : .bike
        let onFoot = { (step: MKRoute.Step) in step.transportType == .walking && travel != .foot }
        let steps = r.steps.map { step in
            RoutedStep(points: step.polyline.coordinates.map { GeoPoint($0) }, text: step.instructions,
                       caution: step.notice != nil || onFoot(step))
        }

        var notices: [String] = []
        if let note { notices.append(note) }
        if travel == .car {
            notices.append(r.hasHighways
                ? String(localized: "This car route uses motorways, which may be banned for bikes.")
                : String(localized: "A car route without motorways: check it before you ride."))
        }
        notices += r.advisoryNotices + r.steps.compactMap(\.notice)
        if r.steps.contains(where: onFoot) { notices.append(String(localized: "Part of this route is on foot.")) }
        var seen = Set<String>()

        return RoutedDestination(route: route, instructions: RoutedStep.instructions(steps), steps: steps,
                                 // Apple's time for a car says nothing about a bike.
                                 expectedTravelTime: travel == .car ? route.estimatedDuration : r.expectedTravelTime,
                                 travel: travel, notices: notices.filter { seen.insert($0).inserted },
                                 provider: .appleMaps)
    }

    /// Legs through the stops as one route: the points joined (the shared stop once), the steps one
    /// after the other, the times added.
    private static func chained(_ legs: [RoutedDestination], to destination: Destination, id: UUID,
                                note: String?) -> RoutedDestination {
        var points: [CLLocationCoordinate2D] = []
        var steps: [RoutedStep] = []
        var notices: [String] = note.map { [$0] } ?? []
        var time: TimeInterval = 0
        for leg in legs {
            var pts = leg.route.points
            if let end = points.last, let start = pts.first, Geo.distance(end, start) < 1 { pts.removeFirst() }
            points += pts
            steps += leg.steps
            time += leg.expectedTravelTime
            notices += leg.notices
        }
        var seen = Set<String>()
        let route = GPXRoute(id: id, name: destination.name, points: points)
        return RoutedDestination(route: route, instructions: RoutedStep.instructions(steps), steps: steps,
                                 expectedTravelTime: time, travel: legs.first?.travel ?? .bike,
                                 notices: notices.filter { seen.insert($0).inserted }, provider: .appleMaps)
    }

    /// Apple's bike routes. The symbol came with Xcode 26 / Swift 6.2, though it's marked iOS 14+: an
    /// iOS that can't do them answers with an error, which the rider sees.
    private static var bikeTransport: MKDirectionsTransportType? {
        #if compiler(>=6.2)
        return MKDirectionsTransportType.cycling
        #else
        return nil
        #endif
    }
}

extension MKMultiPoint {
    var coordinates: [CLLocationCoordinate2D] {
        var c = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&c, range: NSRange(location: 0, length: pointCount))
        return c
    }
}

/// A route as a minimal GPX (one track), to save a routed destination in the library. Points with an
/// elevation (BRouter's) keep it in `<ele>`, so the saved route has a profile and "Climb left".
enum GPXWriter {
    static func data(name: String, points: [CLLocationCoordinate2D], elevations: [Double?] = [],
                     creator: String = "rehalo") -> Data {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(escape(creator))" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(escape(name))</name><trkseg>

        """
        for (i, p) in points.enumerated() {
            if i < elevations.count, let e = elevations[i] {
                s += String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\"><ele>%.1f</ele></trkpt>\n", p.latitude, p.longitude, e)
            } else {
                s += String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\"/>\n", p.latitude, p.longitude)
            }
        }
        s += "</trkseg></trk>\n</gpx>\n"
        return Data(s.utf8)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
