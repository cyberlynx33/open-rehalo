import Foundation
import CoreLocation
import SH2Protocol

/// Routes with a BRouter server (docs/APP_SPEC.md M17): the base URL from Settings (BRouter itself,
/// or a proxy such as sh2-server's `/routing/brouter`), `GET <base>/brouter?…&format=geojson`
/// (`BRouterRequest`), the answer read by `BRouterRoute`: elevation and typed manoeuvres for the
/// ring's own arrows and roundabouts. Up to `RoutingService.maxOptions` options: the best, then the
/// server's alternatives when they differ.
struct BRouterRouteProvider: RouteProvider {
    let baseURL: URL
    /// The rider's access token when the base URL is their own sh2-server, whose proxy may require it
    /// (`Authorization: Bearer`); nil for a plain BRouter.
    var accessToken: String?

    var kind: RouteProviderKind { .brouter }

    /// Seconds before a request is given up: a slow NAS over a tunnel can take a while on a long route.
    static let timeout: TimeInterval = 40
    /// Alternatives asked for after the best route (`alternativeidx` 1…), best effort.
    static let alternatives = RoutingService.maxOptions - 1
    /// Two answers whose lengths are within this are the same route.
    static let sameLengthWithin = 2.0

    func routes(to destination: Destination, from origin: CLLocationCoordinate2D, via stops: [CLLocationCoordinate2D],
                profile: RouteProfile, id: UUID) async throws -> [RoutedDestination] {
        let points = [GeoPoint(origin)] + stops.map { GeoPoint($0) } + [GeoPoint(destination.coordinate)]
        let best = try await fetch(points, profile: profile, alternative: 0)
        var routes = [best]
        // The alternatives in parallel; one that fails or repeats the best is simply not offered.
        let more = await withTaskGroup(of: (Int, BRouterRoute?).self) { group in
            for i in 1...Self.alternatives {
                group.addTask { (i, try? await self.fetch(points, profile: profile, alternative: i)) }
            }
            var out: [(Int, BRouterRoute)] = []
            for await (i, r) in group { if let r { out.append((i, r)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        for r in more where !routes.contains(where: { abs($0.length - r.length) < Self.sameLengthWithin }) {
            routes.append(r)
        }
        return routes.map { routed($0, to: destination, id: id) }
    }

    /// One leg back onto the route (a reroute): the best route only.
    func leg(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D, profile: RouteProfile,
             id: UUID) async throws -> RoutedDestination {
        let r = try await fetch([GeoPoint(origin), GeoPoint(target)], profile: profile, alternative: 0)
        return routed(r, to: Destination(id: id, coordinate: target, name: String(localized: "Back to the route")), id: id)
    }

    func fetch(_ points: [GeoPoint], profile: RouteProfile, alternative: Int) async throws -> BRouterRoute {
        guard let url = BRouterRequest.url(base: baseURL, points: points, profile: profile.brouterProfile,
                                           alternative: alternative) else { throw RouteError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue("application/geo+json, application/vnd.geo+json, application/json, text/plain",
                         forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw SH2ServerError.transport(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A 401 from the proxy lets `AuthStore.authorized` refresh the token and try again.
            let body = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SH2ServerError.http(http.statusCode, body.isEmpty ? "(no body)" : body)
        }
        return try BRouterRoute.parse(data)
    }

    func routed(_ r: BRouterRoute, to destination: Destination, id: UUID) -> RoutedDestination {
        let route = GPXRoute(id: id, name: destination.name, points: r.points.map { CLLocationCoordinate2D($0) },
                             elevations: r.elevations)
        return RoutedDestination(route: route, instructions: RoutedStep.instructions(r.steps), steps: r.steps,
                                 expectedTravelTime: r.duration ?? route.estimatedDuration, travel: .bike,
                                 notices: [], provider: .brouter)
    }
}
