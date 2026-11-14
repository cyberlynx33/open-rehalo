import Foundation
import Combine
import SH2Protocol

/// The route currently selected on the Map tab (UX_DESIGN §4.2) — the one "▶ NAVEGAR" starts.
///
/// Small shared hook between screens:
/// - The Map tab shows `route` in its bottom card and starts Navigating from it.
/// - **M9 (routes library):** library routes are selected through `RouteLibrary.select(_:navigate:)`
///   (marks the route used, then calls `select(_:subtitle:navigate:)` here). `navigate: true` switches
///   to the Map tab and the Map tab starts Navigating (it consumes `pendingNavigation`).
///   Nothing is selected at launch: the map opens on the rider, recent routes are one search away.
/// - `demoRoute(isDemo:)`: the bundled `DemoRoute.gpx` ("Demo route · City centre"), or the built-in
///   `GPXRoute.demo` loop in demo mode if the bundle lacks it. The UI saves it via
///   `RouteLibrary.addDemoRoute()`.
@MainActor
final class RouteSelection: ObservableObject {
    static let shared = RouteSelection()

    @Published private(set) var route: GPXRoute?
    /// Where the route came from ("Wikiloc", "Files"…), shown under its name. Optional.
    @Published private(set) var subtitle: String?
    /// A saved destination's typed steps (`RouteLibrary.routedSteps(for:)`), so riding it again keeps
    /// its manoeuvres; empty for a GPX.
    @Published private(set) var routedSteps: [RoutedStep] = []
    /// Set by `select(…, navigate: true)`; the Map tab resets it and starts Navigating.
    @Published var pendingNavigation = false

    private init() {}

    func select(_ route: GPXRoute?, subtitle: String? = nil, steps: [RoutedStep] = [], navigate: Bool = false) {
        self.route = route
        self.subtitle = route == nil ? nil : subtitle
        routedSteps = route == nil ? [] : steps
        if navigate, route != nil {
            AppRouter.shared.tab = .map
            pendingNavigation = true
        }
    }

    func clear() { select(nil) }

    /// The demo route offered by "Use demo route": the bundled GPX if the app ships one, else the
    /// built-in loop while the simulated Halo is active. Nil = don't offer it.
    static func demoRoute(isDemo: Bool) -> GPXRoute? {
        if let bundled = bundledDemoRoute { return bundled }
        return isDemo ? .demo : nil
    }

    /// `DemoRoute.gpx` in the app bundle (parsed once).
    static let bundledDemoRoute: GPXRoute? = {
        guard let url = Bundle.main.url(forResource: "DemoRoute", withExtension: "gpx"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? GPXDocumentParser().parse(data: data)
    }()
}
