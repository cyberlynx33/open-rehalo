import Foundation
import CoreLocation
import SH2Protocol

/// Which routing service a route comes from (docs/APP_SPEC.md M17): BRouter when the rider has set
/// its URL in Settings and it answers, Apple Maps otherwise, and the rider is told when Apple stands
/// in. Also the "back to the route" leg of a reroute, BRouter only.
@MainActor
final class RoutingService {
    static let shared = RoutingService()

    /// Most options the rider chooses from.
    static let maxOptions = 3

    private let settings: AppSettings
    private let auth: AuthStore

    init(settings: AppSettings = .shared, auth: AuthStore = .shared) {
        self.settings = settings
        self.auth = auth
    }

    /// The BRouter server from Settings, nil when none is set.
    var brouterURL: URL? { settings.brouterURL }
    var hasBRouter: Bool { brouterURL != nil }

    /// Routes from `origin` (nil: the current location, which only Apple can take as such) to
    /// `destination` through `stops`, best first. BRouter's when it is set and answers; else Apple's,
    /// with a notice saying so and why.
    func routes(to destination: Destination, from origin: CLLocationCoordinate2D?,
                via stops: [CLLocationCoordinate2D] = [], profile: RouteProfile, id: UUID) async throws -> [RoutedDestination] {
        var reason: String?
        if let url = brouterURL {
            if let origin {
                do {
                    return try await withBRouter(url) { try await $0.routes(to: destination, from: origin, via: stops,
                                                                              profile: profile, id: id) }
                } catch {
                    reason = String(localized: "BRouter didn't answer (\(error.localizedDescription)).")
                }
            } else {
                reason = String(localized: "BRouter needs your position, which isn't known yet.")
            }
        }
        var options: [RoutedDestination]
        if let origin {
            options = try await AppleRouteProvider().routes(to: destination, from: origin, via: stops, profile: profile, id: id)
        } else {
            options = try await DestinationRouter.routes(to: destination, from: nil, via: stops, profile: profile, id: id)
        }
        if let reason {
            let note = String(localized: "\(reason) Calculated with Apple Maps.")
            options = options.map { var o = $0; o.notices.insert(note, at: 0); return o }
        }
        return options
    }

    /// The best route, where the rider doesn't choose (a lead-in to a route's start).
    func route(to destination: Destination, from origin: CLLocationCoordinate2D?, profile: RouteProfile,
               id: UUID) async throws -> RoutedDestination {
        guard let best = try await routes(to: destination, from: origin, profile: profile, id: id).first else {
            throw RouteError.noRoute
        }
        return best
    }

    /// A leg from the rider back onto the route (`RideEngine.rerouted`): BRouter only, as Apple's
    /// profiles don't match the ride's. Throws when BRouter isn't set.
    func rerouteLeg(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D,
                    profile: RouteProfile, id: UUID) async throws -> RoutedDestination {
        guard let url = brouterURL else { throw RouteError.badURL }
        return try await withBRouter(url) { try await $0.leg(from: origin, to: target, profile: profile, id: id) }
    }

    /// Run a BRouter call. When the BRouter URL is the rider's own sh2-server (same host and port) and
    /// they are logged in, the proxy gets their access token as `Authorization: Bearer`, refreshed once
    /// on a 401 like the other server calls; any other server gets nothing of the rider's.
    private func withBRouter<T>(_ url: URL, _ call: @escaping (BRouterRouteProvider) async throws -> T) async throws -> T {
        if Self.isOwnServer(url, server: settings.serverURL), auth.isLoggedIn {
            return try await auth.authorized { jwt in
                try await call(BRouterRouteProvider(baseURL: url, accessToken: jwt))
            }
        }
        return try await call(BRouterRouteProvider(baseURL: url))
    }

    /// The BRouter URL points at the rider's own server: the same scheme, host and port.
    static func isOwnServer(_ url: URL, server: URL?) -> Bool {
        guard let server else { return false }
        return url.scheme?.lowercased() == server.scheme?.lowercased()
            && url.host?.lowercased() == server.host?.lowercased()
            && (url.port ?? Self.defaultPort(url)) == (server.port ?? Self.defaultPort(server))
    }

    private static func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }
}
