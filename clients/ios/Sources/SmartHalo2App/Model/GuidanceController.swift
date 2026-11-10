import Foundation
import Combine
import CoreLocation
import UIKit
import SH2Protocol

/// Follows a GPX route using live location (or a simulated rider in demo mode), drives the ring's
/// nav pointer, and exposes what the Navigating screen shows (next manoeuvre, remaining distance,
/// progress, speed, elapsed time, off-route distance).
///
/// One app-wide instance (`shared`): navigation outlives a Halo drop / reconnect and talks to
/// whatever ring `HaloConnection` currently holds. Guidance without a Halo is phone-only.
///
/// The ride logic itself is `RideEngine` (SH2Nav); this class feeds it fixes and publishes what it
/// says.
///
/// Ring logic: a reimplementation of the official app's GPX navigation (`NavDirector` in SH2Nav,
/// docs/protocol/navigation.md) — every fix goes through it and its commands go to the ring as they
/// are: intro at start, turn arcs before each turn of the GPX, the orange pointer back to the route,
/// "ride to calibrate" until the direction of travel is known, sounds, and the arrival sequence (it
/// also decides arrival). The screen shows the same decisions (next turn, off-route), so screen and
/// ring agree; only progress, distance left and speed are its own. No phone-side off-route sound
/// (UX §10).
///
/// Also (additions): a destination routed by Apple (`start(_:instructions:)`, street names on
/// the ring), a lead-in to a route's start chained before it (`leadIn:`), joining a route at its
/// nearest point (`joinNearest:`), and the official "as the crow flies" mode (`startCompass`).
@MainActor
final class GuidanceController: ObservableObject {
    static let shared = GuidanceController(connection: .shared)

    /// End-of-ride numbers for the summary screen.
    struct Summary: Equatable {
        let routeName: String
        let distance: Double          // metres actually ridden
        let duration: TimeInterval
        let averageSpeed: Double      // m/s
        let completed: Bool           // true = arrived, false = stopped by the user
    }

    /// Snapshot of what's on screen — what a Live Activity (M12) needs.
    struct NavState: Equatable {
        let routeName: String
        /// Banner manoeuvre: `.offRoute` while off-route, `.straight` when the next turn is far.
        let turn: TurnKind
        /// Metres to `turn` (to the route when off-route).
        let turnDistance: Double
        let speed: Double?            // m/s, nil before the first fix
        let remaining: Double         // metres
        let progress: Double          // 0…1
        let haloConnected: Bool
        /// Riding the route the wrong way (matched engine).
        var wrongWay = false
    }

    // MARK: Published state

    @Published private(set) var route: GPXRoute?
    @Published private(set) var following = false
    @Published private(set) var progress: Double = 0      // 0…1 along the route
    @Published private(set) var offRoute = false
    @Published private(set) var status = ""
    @Published private(set) var userCoord: CLLocationCoordinate2D?
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

    /// Next manoeuvre ahead (`.straight` when it's more than `straightBeyond` away).
    @Published private(set) var nextTurn: TurnKind = .straight
    /// Metres to `nextTurn`, the number the ring shows.
    @Published private(set) var nextTurnDistance: Double = 0
    @Published private(set) var remainingDistance: Double = 0
    /// Climb still ahead (nil when the route has no elevation).
    @Published private(set) var remainingGain: Double?
    /// Metres from the rider to the route (meaningful while `offRoute`).
    @Published private(set) var offRouteDistance: Double = 0
    /// The pointer back to the route, degrees off the direction of travel (nil until it's known).
    @Published private(set) var offRouteBearing: Int?
    /// The rider has been on the route. Until then, off-route means on the way to its start.
    @Published private(set) var reachedOrigin = false
    /// A routed destination's text for `nextTurn` (the street).
    @Published private(set) var nextTurnText: String?
    /// Ground speed, m/s (nil until the first fix).
    @Published private(set) var speed: Double?
    /// Direction of travel, degrees (GPS course while moving, else the route's direction).
    @Published private(set) var heading: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    /// Metres actually ridden since start.
    @Published private(set) var distanceRidden: Double = 0
    /// Bumps on every processed location fix (SwiftUI `onChange` hook for the follow camera).
    @Published private(set) var fixCount = 0
    /// The latest raw fix (the follow camera dead-reckons from it between fixes).
    private(set) var lastLocation: CLLocation?
    /// True while navigating with a Halo that was connected and dropped (banner, UX §5.5).
    @Published private(set) var haloLost = false
    /// Set when a ride ends; cleared by `dismissSummary()`.
    @Published private(set) var summary: Summary?
    /// True while the rider is simulated (demo mode).
    @Published private(set) var simulated = false
    /// The destination of an "as the crow flies" ride (Compass); nil when following a route.
    @Published private(set) var compassTarget: Destination?
    /// Compass: the destination's direction relative to the rider's, degrees (+ = right).
    @Published private(set) var compassBearing: Double = 0
    /// Metres left of the lead-in to the route's start ("Lead me to the start"); nil when there is
    /// none or it's done.
    @Published private(set) var toStart: Double?
    /// Riding the route the wrong way (matched engine, docs/MAP_MATCHING_SPEC.md §9.2).
    @Published private(set) var wrongWay = false
    /// The wrong-way banner can offer to invert the route (a GPX ride, lead-in done).
    @Published private(set) var canInvert = false
    /// Bumps when the wrong-way haptic should play: at most `maxWrongWayAlerts` in a row, ≥ 30 s apart.
    @Published private(set) var wrongWayAlerts = 0

    var locationAuthorized: Bool {
        locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways
    }
    var locationDenied: Bool { locationStatus == .denied || locationStatus == .restricted }
    var hasFix: Bool { fixCount > 0 }

    var navState: NavState? {
        guard following, let route else { return nil }
        return NavState(routeName: route.name,
                        turn: offRoute ? .offRoute : nextTurn,
                        turnDistance: offRoute ? offRouteDistance : nextTurnDistance,
                        speed: speed, remaining: remainingDistance, progress: progress,
                        haloConnected: connection.state == .connected, wrongWay: wrongWay)
    }

    // MARK: Internals

    private let connection: HaloConnection
    private var controller: DeviceController? { connection.controller }
    private let tracker = LocationTracker()
    private var bag = Set<AnyCancellable>()

    /// The ride in progress.
    private var engine: RideEngine?
    /// The iPhone compass, for Compass rides while the rider is slow or stopped.
    private var headingTracker: HeadingTracker?
    private var carouselSub: AnyCancellable?
    private var haloWasConnected = false
    /// A real (non-demo) ride went to the background: ask for *Always* when the app is back.
    private var backgroundedWhileNavigating = false
    /// Wrong-way haptics played since the rider last rode the right way, and when the last one did.
    private var wrongWayAlertCount = 0
    private var lastWrongWayAlert: Date?
    private static let maxWrongWayAlerts = 3
    private static let wrongWayAlertSpacing: TimeInterval = 30

    private var startedAt: Date?
    private var clockTask: Task<Void, Never>?

    // Demo: a simulated rider moves along the route on a timer.
    private var demoTask: Task<Void, Never>?
    private var demoAlong: Double = 0

    init(connection: HaloConnection) {
        self.connection = connection
        tracker.onLocation = { [weak self] loc in self?.handle(loc) }
        tracker.onAuth = { [weak self] s in self?.locationStatus = s }
        locationStatus = tracker.authorizationStatus

        connection.$state
            .removeDuplicates()
            .sink { [weak self] s in self?.connectionChanged(s) }
            .store(in: &bag)

        // UX §4.1: *Always* is requested the first time navigation goes to the background — shown
        // when the rider is back in the app (a prompt while the phone is in a pocket is useless).
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self, self.following, !self.simulated else { return }
                self.backgroundedWhileNavigating = true
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.backgroundedWhileNavigating else { return }
                self.backgroundedWhileNavigating = false
                self.tracker.requestAlwaysOnce()
            }
            .store(in: &bag)
    }

    // MARK: - Public API

    /// Ask for location permission (Map tab recenter / first use).
    func requestLocationPermission() { tracker.requestAuthorization() }

    /// One fix while not navigating, so `lastLocation` is fresh for the Map tab's checks (how far
    /// the rider is from a route's start). The tracker stops again as soon as it arrives (`handle`).
    func primeLocation() {
        guard !following, locationAuthorized else { return }
        tracker.start()
    }

    /// Start guiding along `route`. Uses the simulated rider when the demo Halo is active.
    /// - `instructions`: a routed destination's instructions (street names on the ring).
    /// - `routedSteps`: a routed destination's own steps, for its turns.
    /// - `leadIn`: a route to `route`'s start, ridden first as part of the same ride.
    /// - `joinNearest`: join the route at its nearest point instead of its start.
    func start(_ route: GPXRoute, instructions: [(location: NavLocation, text: String)] = [],
               routedSteps: [RoutedStep] = [], leadIn: RoutedDestination? = nil, joinNearest: Bool = false) {
        let ride = leadIn.map { Self.chain($0.route, before: route) } ?? route
        let texts = (leadIn?.instructions ?? []) + instructions
        let engine = RideEngine(route: ride.geometry, title: route.name, settings: ringSettings, instructions: texts,
                                routedSteps: routedSteps, leadInLength: leadIn?.route.length ?? 0,
                                joinNearest: joinNearest, engine: AppSettings.shared.navigationEngine)
        begin(ride, engine)
        RideRecorder.shared.begin(RideTrace.Header(engine: engine, title: route.name, instructions: texts,
                                                   routedSteps: routedSteps, joinNearest: joinNearest,
                                                   appVersion: Self.appVersion))
        if let cmds = self.engine?.start(ringConnected: connection.state == .connected) { sendRing(cmds) }
        watchCarousel()
    }

    /// "As the crow flies" to `destination` (Compass): the ring points at it, no route. `origin` (the
    /// rider, when known) draws a straight line to it on the map.
    func startCompass(to destination: Destination, from origin: CLLocationCoordinate2D?) {
        begin(GPXRoute(id: destination.id, name: destination.name,
                       points: [origin ?? destination.coordinate, destination.coordinate]),
              RideEngine(compassTo: GeoPoint(destination.coordinate), from: origin.map { GeoPoint($0) },
                         title: destination.name, settings: ringSettings))
        compassTarget = destination
        if let engine {
            RideRecorder.shared.begin(RideTrace.Header(engine: engine, title: destination.name,
                                                       appVersion: Self.appVersion))
        }
        if let cmds = engine?.start(ringConnected: connection.state == .connected) { sendRing(cmds) }
        if !simulated {
            let h = HeadingTracker()
            h.start()
            headingTracker = h
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var ringSettings: NavDirector.Settings {
        .init(metric: AppSettings.shared.units == .metric, carouselCards: AppSettings.shared.ringCards)
    }

    /// A lead-in to the start followed by the route, as one route with the route's id and name: the
    /// ring sees one path and the Live Activity keeps going.
    static func chain(_ leadIn: GPXRoute, before route: GPXRoute) -> GPXRoute {
        GPXRoute(id: route.id, name: route.name, geometry: .chain(leadIn.geometry, before: route.geometry))
    }

    /// Reset everything for a new ride along `route` and start the clock and the rider.
    private func begin(_ route: GPXRoute, _ ride: RideEngine) {
        if following { finish(completed: false, showSummary: false) }
        engine = ride
        compassTarget = nil
        headingTracker?.stop()
        headingTracker = nil
        self.route = route
        following = true
        summary = nil
        elapsed = 0
        userCoord = nil
        lastLocation = nil
        apply(ride.snapshot)
        haloWasConnected = connection.state == .connected
        haloLost = false

        startedAt = Date()
        clockTask?.cancel()
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.following, let t0 = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(t0)
            }
        }

        simulated = connection.isDemo
        if simulated {
            status = "DEMO — simulating GPS along the route…"
            demoAlong = 0
            demoTask?.cancel()
            demoTask = Task { @MainActor [weak self] in
                var tick = 0.0
                while !Task.isCancelled {
                    guard let self, self.following else { return }
                    self.demoStep(tick: tick)
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            status = "Waiting for GPS…"
            tracker.start(background: true)
        }
    }

    /// User pressed PARAR (after confirming): stop guiding, `navOff` to the ring, show the summary.
    func stop() { finish(completed: false) }

    // MARK: - Wrong way (matched engine)

    /// "Invert route" on the wrong-way banner: the same ride carries on along the route turned around,
    /// from where the rider is (docs/MAP_MATCHING_SPEC.md §9.3). Not through `start`: the clock, the
    /// distance ridden, the trace and the Live Activity carry on, and the ring gets no intro.
    func invert() {
        guard following, let route, let current = engine, let inverted = current.inverted() else { return }
        engine = inverted.engine
        self.route = GPXRoute(id: route.id, name: route.name, geometry: inverted.engine.route)
        RideRecorder.shared.record(RideTrace.Entry(fix: nil, engine: inverted.engine, commands: inverted.commands,
                                                   event: "invert"))
        sendRing(inverted.commands)
        apply(inverted.engine.snapshot)
    }

    /// "Ignore" on the wrong-way banner: silent until the rider rides the right way again.
    func ignoreWrongWay() {
        guard following, var ride = engine else { return }
        ride.ignoreWrongWay()
        engine = ride
        RideRecorder.shared.record(RideTrace.Entry(fix: nil, engine: ride, commands: [], event: "ignoreWrongWay"))
        apply(ride.snapshot)
    }

    /// Clear the end-of-ride summary (summary "Done").
    func dismissSummary() { summary = nil }

    // MARK: - Ride lifecycle

    private func finish(completed: Bool, showSummary: Bool = true) {
        guard following else { return }
        following = false
        RideRecorder.shared.end()
        demoTask?.cancel(); demoTask = nil
        clockTask?.cancel(); clockTask = nil
        tracker.stop()
        if let t0 = startedAt { elapsed = Date().timeIntervalSince(t0) }
        startedAt = nil
        haloLost = false
        status = completed ? "Arrived 🎉" : "Stopped."
        if completed {
            progress = 1
            remainingDistance = 0
            nextTurn = .arrival
            nextTurnDistance = 0
        }
        if showSummary, let route {
            summary = Summary(routeName: route.name,
                              distance: distanceRidden,
                              duration: elapsed,
                              averageSpeed: elapsed > 0 ? distanceRidden / elapsed : 0,
                              completed: completed)
        }
        // The user stopped: clear the ring (on arrival the director already sent its sequence).
        if var e = engine { sendRing(e.stop()) }
        engine = nil
        headingTracker?.stop()
        headingTracker = nil
        toStart = nil
        carouselSub = nil
    }

    private func connectionChanged(_ s: HaloConnectionState) {
        guard following else { haloLost = false; return }
        if s == .connected {
            haloLost = false
            haloWasConnected = true
            // The next fix (≈ 1 s) puts the guidance back on the ring; an intro that couldn't be
            // shown at start goes now.
            if let cmds = engine?.ringConnected() { sendRing(cmds) }
            watchCarousel()
        } else if haloWasConnected {
            haloLost = true
        }
    }

    // MARK: - Demo rider

    /// Move the simulated rider ~6 m/s (with a little variation) along the route.
    private func demoStep(tick: Double) {
        guard let route, route.points.count > 1 else { return }
        let v = 6.0 + 1.2 * sin(tick / 7)
        demoAlong = min(route.length, demoAlong + v)
        let c = route.coordinate(at: demoAlong)
        let loc = CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                             course: route.heading(at: demoAlong), speed: v, timestamp: Date())
        handle(loc)
    }

    // MARK: - Location handling

    private func handle(_ loc: CLLocation) {
        userCoord = loc.coordinate
        lastLocation = loc
        guard following, var ride = engine else {
            tracker.stop()          // a primed fix (`primeLocation`): one is enough
            return
        }
        let compass = headingTracker?.isReliable == true ? headingTracker?.heading : nil
        let fix = RideFix(loc)
        let result = ride.update(fix, compassHeading: compass)
        engine = ride
        RideRecorder.shared.record(RideTrace.Entry(fix: fix, engine: ride, commands: result.commands,
                                                   arrived: result.arrived))
        sendRing(result.commands)
        if result.arrived {
            finish(completed: true)
            return
        }
        apply(ride.snapshot)
        if ride.compassTarget != nil {
            status = "Compass."
        } else {
            status = offRoute ? "Off route — pointer shows the way back." : "On route."
        }
    }

    /// Publish what the ride says the screen shows. `fixCount` last: it is the follow camera's cue.
    private func apply(_ s: RideSnapshot) {
        progress = s.progress
        offRoute = s.offRoute
        offRouteDistance = s.offRouteDistance
        offRouteBearing = s.offRouteBearing
        reachedOrigin = s.reachedOrigin
        nextTurn = s.nextTurn
        nextTurnDistance = s.nextTurnDistance
        nextTurnText = s.nextTurnText
        remainingDistance = s.remainingDistance
        remainingGain = s.remainingGain
        speed = s.speed
        heading = s.heading
        distanceRidden = s.distanceRidden
        compassBearing = s.compassBearing
        toStart = s.toStart
        updateWrongWay(s.wrongWay ?? false)
        canInvert = s.canInvert ?? false
        fixCount = s.fixCount
    }

    /// The warning haptic on a new wrong-way warning: a few times, spaced out, and again only once the
    /// rider has ridden the right way in between.
    private func updateWrongWay(_ now: Bool) {
        if now && !wrongWay {
            let spaced = lastWrongWayAlert.map { Date().timeIntervalSince($0) >= Self.wrongWayAlertSpacing } ?? true
            if wrongWayAlertCount < Self.maxWrongWayAlerts && spaced {
                wrongWayAlertCount += 1
                lastWrongWayAlert = Date()
                wrongWayAlerts += 1
            }
        } else if !now && wrongWay && engine?.matcher?.last.wrongWay == WrongWayDetector.State.none {
            wrongWayAlertCount = 0                  // rode the right way again (not just ignored)
        }
        wrongWay = now
    }

    // MARK: - Ring (official navigation)

    private func sendRing(_ commands: [NavCommand]) {
        guard connection.state == .connected, let ring = controller else { return }
        ring.sendNav(commands)
    }

    /// The ring reports its carousel card; on the Navigation card it gets the card's content
    /// (`CarouselController.updateNavigationCard`). Every report gets its answer, repeats too: on the
    /// Navigation card the ring reports every other second (`RideTask.c`, `CarouselTimerCB`) so that
    /// the distance to the next turn stays fresh between turns, as the official app answers them all
    /// (`CarouselController.handleNewNotification`).
    private func watchCarousel() {
        carouselSub = controller?.$carouselCard
            .sink { [weak self] card in
                guard let self, self.following, let cmds = self.engine?.carouselChanged(card: card) else { return }
                self.sendRing(cmds)
            }
    }
}
