import XCTest
@testable import SH2Nav

/// A simulated rider for the matched engine (docs/MAP_MATCHING_SPEC.md §12.1): routes drawn in local
/// metres, a rider moving along a path at a set speed with correlated GPS noise from a seeded generator,
/// so every run is the same.
struct RideSim {
    static let lat0 = 41.39, lon0 = 2.16

    static func point(_ east: Double, _ north: Double) -> GeoPoint {
        GeoPoint(lat0 + north / 110_540, lon0 + east / (111_320 * cos(lat0 * .pi / 180)))
    }

    static func local(_ p: GeoPoint) -> (east: Double, north: Double) {
        ((p.lon - lon0) * 111_320 * cos(lat0 * .pi / 180), (p.lat - lat0) * 110_540)
    }

    /// A polyline through `vertices` (east, north), a point every `step` metres.
    static func path(_ vertices: [(Double, Double)], step: Double = 10) -> [GeoPoint] {
        guard let first = vertices.first else { return [] }
        var out = [point(first.0, first.1)]
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            let len = hypot(b.0 - a.0, b.1 - a.1)
            let n = max(1, Int((len / step).rounded()))
            for i in 1...n {
                let t = Double(i) / Double(n)
                out.append(point(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
            }
        }
        return out
    }

    static func route(_ vertices: [(Double, Double)]) -> RouteGeometry {
        RouteGeometry(points: path(vertices))
    }

    /// SplitMix64.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    var random: Random
    let sigma: Double
    var noise = (0.0, 0.0)
    var time = 1000.0
    /// Correlation of the noise from one second to the next.
    let rho = 0.8

    init(seed: UInt64, sigma: Double) {
        random = Random(state: seed)
        self.sigma = sigma
        noise = (random.gaussian() * sigma, random.gaussian() * sigma)
    }

    var accuracy: Double { max(5, sigma * 1.5) }

    /// One fix at `p` (true position), `dt` seconds after the last.
    mutating func fix(at p: GeoPoint, speed: Double, dt: Double = 1) -> RideFix {
        let k = (1 - rho * rho).squareRoot()
        noise = (rho * noise.0 + k * sigma * random.gaussian(), rho * noise.1 + k * sigma * random.gaussian())
        time += dt
        let l = Self.local(p)
        let q = Self.point(l.east + noise.0, l.north + noise.1)
        return RideFix(lat: q.lat, lon: q.lon, horizontalAccuracy: accuracy, speed: speed, time: time)
    }

    /// Fixes every second riding `path` from `from` to `to` metres along it at `speed`; with each, the
    /// true distance along `path`.
    mutating func ride(_ path: RouteGeometry, from: Double = 0, to: Double? = nil,
                       speed: Double = 5.5) -> [(fix: RideFix, truth: Double)] {
        let end = to ?? path.length
        var out: [(RideFix, Double)] = []
        var s = from
        let dir: Double = end >= from ? 1 : -1
        while dir > 0 ? s <= end : s >= end {
            out.append((fix(at: path.coordinate(at: s), speed: speed), s))
            s += dir * speed
        }
        return out
    }

    /// Fixes standing still at `p` for `seconds`.
    mutating func stand(at p: GeoPoint, seconds: Int) -> [RideFix] {
        (0..<seconds).map { _ in fix(at: p, speed: 0) }
    }
}

final class RouteMatcherTests: XCTestCase {

    let seeds: [UInt64] = Array(1...20)

    // MARK: Straight and parallel

    func testStraightRouteWithNoiseStaysOnRoute() {
        let route = RideSim.route([(0, 0), (0, 2000)])
        for sigma in [5.0, 10.0, 20.0] {
            for seed in seeds {
                var sim = RideSim(seed: seed, sigma: sigma)
                var m = RouteMatcher(route: route)
                var wasOn = false
                var worst = 0.0
                for (fix, truth) in sim.ride(route) {
                    let r = m.update(fix)
                    if r.status == .on { wasOn = true }
                    if wasOn {
                        XCTAssertNotEqual(r.status, .off, "σ \(sigma) seed \(seed) at \(truth) m")
                        if r.confident, let b = r.best { worst = max(worst, abs(b.along - truth)) }
                    }
                    // A wrong way may be suspected (it only holds the step) but never confirmed; at
                    // σ ≤ 10 m not even suspected.
                    if sigma <= 10 { XCTAssertEqual(r.wrongWay, .none, "σ \(sigma) seed \(seed)") }
                    XCTAssertNotEqual(r.wrongWay, .confirmed, "σ \(sigma) seed \(seed)")
                }
                XCTAssertTrue(wasOn)
                // Along the route, the error is the GPS noise along it, which no matcher can see.
                if sigma <= 10 { XCTAssertLessThan(worst, 4 * sigma, "σ \(sigma) seed \(seed)") }
            }
        }
    }

    /// The rider takes a parallel street for 300 m.
    func parallel(offset: Double, seed: UInt64) -> (offAt: Double?, off: Bool) {
        let route = RideSim.route([(0, 0), (0, 1200)])
        let rider = RideSim.route([(0, 0), (0, 300), (offset, 330), (offset, 630), (0, 660), (0, 1200)])
        var sim = RideSim(seed: seed, sigma: 5)
        var m = RouteMatcher(route: route)
        var offAt: Double?
        for (fix, truth) in sim.ride(rider) {
            let r = m.update(fix)
            if r.status == .off && m.last.joined && offAt == nil { offAt = truth }
        }
        return (offAt, offAt != nil)
    }

    /// The leave threshold is max(30 m, 2 × accuracy): a street 15 m away never leaves the route; at
    /// 20–25 m with σ = 5 m noise, an occasional exit is the price of noticing a 40 m one in seconds.
    func testParallelStreetCloseByStaysOnRoute() {
        for seed in seeds { XCTAssertFalse(parallel(offset: 15, seed: seed).off, "seed \(seed)") }
        XCTAssertLessThanOrEqual(seeds.filter { parallel(offset: 20, seed: $0).off }.count, 2)
    }

    func testParallelStreetFurtherAwayLeavesTheRouteSoon() {
        for seed in seeds {
            let r = parallel(offset: 40, seed: seed)
            // On the parallel street from ~330 m: off within 12 s (66 m at 5.5 m/s).
            XCTAssertNotNil(r.offAt, "seed \(seed)")
            if let at = r.offAt { XCTAssertLessThan(at, 330 + 12 * 5.5, "seed \(seed)") }
        }
    }

    // MARK: Shapes

    func testOutAndBackFollowsTheReturnLegWithoutWrongWay() {
        let route = RideSim.route([(0, 0), (0, 500), (0, 0)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            for (fix, truth) in sim.ride(route) {
                let r = m.update(fix)
                XCTAssertEqual(r.wrongWay, .none, "seed \(seed) at \(truth)")
                if truth > 600, truth < 950, r.confident, let b = r.best {
                    XCTAssertGreaterThan(b.along, 520, "seed \(seed) at \(truth)")
                }
            }
            XCTAssertTrue(m.last.arrived, "seed \(seed)")
        }
    }

    func testLoopEndingAtItsStartArrivesOnlyAtTheEnd() {
        let route = RideSim.route([(0, 0), (300, 0), (300, 300), (0, 300), (0, 0)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            var arrivedAt: Double?
            for (fix, truth) in sim.ride(route) where arrivedAt == nil {
                if m.update(fix).arrived { arrivedAt = truth }
            }
            XCTAssertNotNil(arrivedAt, "seed \(seed)")
            XCTAssertGreaterThan(arrivedAt ?? 0, route.length - 75, "seed \(seed)")  // 50 m radius + GPS noise
        }
    }

    func testTwoLapCircuitArrivesAfterTheSecondLap() {
        let lap: [(Double, Double)] = [(0, 0), (300, 0), (300, 300), (0, 300), (0, 0)]
        let route = RideSim.route(lap + lap.dropFirst())
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            var arrivedAt: Double?
            for (fix, truth) in sim.ride(route) where arrivedAt == nil {
                let r = m.update(fix)
                if truth > 1350, truth < 2300, r.confident, let b = r.best {
                    XCTAssertGreaterThan(b.along, 1100, "seed \(seed) at \(truth): lap 2")
                }
                if r.arrived { arrivedAt = truth }
            }
            XCTAssertGreaterThan(arrivedAt ?? 0, route.length - 75, "seed \(seed)")  // 50 m radius + GPS noise
        }
    }

    func testFigureOfEightKeepsThePassThroughTheCrossing() {
        // Through the centre (150, 150) twice, once going north-east, once going north-west.
        let route = RideSim.route([(0, 0), (300, 300), (300, 0), (0, 300), (0, 0)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            for (fix, truth) in sim.ride(route) {
                let r = m.update(fix)
                XCTAssertNotEqual(r.wrongWay, .confirmed, "seed \(seed)")
                if r.confident, let b = r.best, truth > 50 {
                    XCTAssertEqual(b.along, truth, accuracy: 40, "seed \(seed)")
                }
            }
        }
    }

    // MARK: Joining

    func testStartingMidRouteTheRightWayJoinsThere() {
        let route = RideSim.route([(0, 0), (0, 1000)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            var joinedAt: Double?
            for (fix, truth) in sim.ride(route, from: 400, to: 700) where joinedAt == nil {
                if m.update(fix).status == .on { joinedAt = truth }
            }
            XCTAssertLessThan(joinedAt ?? .infinity, 500, "seed \(seed)")         // within 100 m
        }
    }

    func testCrossingTheRouteDoesNotJoin() {
        let route = RideSim.route([(0, 0), (0, 1000)])
        let crossing = RideSim.route([(-200, 500), (200, 500)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            for (fix, _) in sim.ride(crossing) {
                XCTAssertNotEqual(m.update(fix).status, .on, "seed \(seed)")
            }
            XCTAssertFalse(m.last.joined)
        }
    }

    func testStoppedAtALightWithDrift() {
        let route = RideSim.route([(0, 0), (0, 1000)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            for (fix, _) in sim.ride(route, to: 300) { _ = m.update(fix) }
            for fix in sim.stand(at: route.coordinate(at: 300), seconds: 60) {
                let r = m.update(fix)
                XCTAssertEqual(r.status, .on, "seed \(seed)")
                XCTAssertEqual(r.wrongWay, .none, "seed \(seed)")
            }
        }
    }

    func testReacquiresAfterAGPSGap() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            for (fix, _) in sim.ride(route, to: 400) { _ = m.update(fix) }
            sim.time += 30                          // a tunnel: 30 s without fixes, 200 m further on
            var confidentWithin: Int?
            for (i, (fix, truth)) in sim.ride(route, from: 600, to: 800).enumerated() where confidentWithin == nil {
                let r = m.update(fix)
                if r.confident, let b = r.best, abs(b.along - truth) < 20 { confidentWithin = i + 1 }
            }
            XCTAssertLessThanOrEqual(confidentWithin ?? 99, 3, "seed \(seed)")
        }
    }

    // MARK: Wrong way

    func testRidingBackwardsIsConfirmedQuickly() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            for (fix, _) in sim.ride(route, to: 400, speed: 5) { _ = m.update(fix) }
            XCTAssertEqual(m.last.wrongWay, .none)
            var confirmedAfter: Int?
            for (i, (fix, _)) in sim.ride(route, from: 400, to: 0, speed: 5).enumerated() where confirmedAfter == nil {
                if m.update(fix).wrongWay == .confirmed { confirmedAfter = i + 1 }
            }
            // 18 km/h: within 15 s, 75 m.
            XCTAssertLessThanOrEqual(confirmedAfter ?? 99, 15, "seed \(seed)")
        }
    }

    func testWrongWayEndsOnTurningRoundAgain() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        var sim = RideSim(seed: 7, sigma: 5)
        var m = RouteMatcher(route: route)
        for (fix, _) in sim.ride(route, to: 400, speed: 5) { _ = m.update(fix) }
        for (fix, _) in sim.ride(route, from: 400, to: 250, speed: 5) { _ = m.update(fix) }
        XCTAssertEqual(m.last.wrongWay, .confirmed)
        var clearedAfter: Int?
        for (i, (fix, _)) in sim.ride(route, from: 250, to: 450, speed: 5).enumerated() where clearedAfter == nil {
            if m.update(fix).wrongWay == .none { clearedAfter = i + 1 }
        }
        XCTAssertLessThanOrEqual(clearedAfter ?? 99, 15)
    }

    func testIgnoredWrongWayStaysSilentUntilTheRiderGoesForward() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        var sim = RideSim(seed: 3, sigma: 5)
        var m = RouteMatcher(route: route)
        for (fix, _) in sim.ride(route, to: 400, speed: 5) { _ = m.update(fix) }
        for (fix, _) in sim.ride(route, from: 400, to: 250, speed: 5) { _ = m.update(fix) }
        XCTAssertEqual(m.last.wrongWay, .confirmed)
        m.ignoreWrongWay()
        for (fix, _) in sim.ride(route, from: 250, to: 100, speed: 5) {
            XCTAssertEqual(m.update(fix).wrongWay, .ignored)
        }
    }

    func testSwitchbacksAreNotWrongWay() {
        // A climb zigzagging every 40 m.
        var zigzag: [(Double, Double)] = [(0, 0)]
        for i in 1...20 { zigzag.append((i % 2 == 1 ? 120 : 0, Double(i) * 40)) }
        let route = RideSim.route(zigzag)
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            for (fix, _) in sim.ride(route, speed: 4) {
                XCTAssertNotEqual(m.update(fix).wrongWay, .confirmed, "seed \(seed)")
            }
        }
    }

    func testNoWrongWayOnOutAndBackOrSwitchbacksOverManyRuns() {
        let outAndBack = RideSim.route([(0, 0), (0, 400), (0, 0)])
        for seed in 100..<150 as Range<UInt64> {
            var sim = RideSim(seed: seed, sigma: 8)
            var m = RouteMatcher(route: outAndBack)
            for (fix, _) in sim.ride(outAndBack) {
                XCTAssertNotEqual(m.update(fix).wrongWay, .confirmed, "seed \(seed)")
            }
        }
    }

    // MARK: Lead-in

    func testNoMidRouteJoinWhileOnTheLeadIn() {
        // The lead-in runs east along y = 0 to the start (300, 0); the route comes back along it at the
        // end, the same way.
        let lead: [(Double, Double)] = [(0, 0), (300, 0)]
        let gpx: [(Double, Double)] = [(300, 0), (300, 300), (-100, 300), (-100, 0), (600, 0)]
        let route = RideSim.route(lead + gpx.dropFirst())
        let leadIn = 300.0
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route, leadInLength: leadIn)
            for (fix, truth) in sim.ride(route, to: 280) {
                let r = m.update(fix)
                if let b = r.best, r.status == .on { XCTAssertLessThan(b.along, leadIn + 30, "seed \(seed) at \(truth)") }
            }
        }
    }

    // MARK: Performance

    func testUpdateOnALongRouteIsFast() {
        var vertices: [(Double, Double)] = []
        for i in 0..<100 { vertices.append((Double(i % 2) * 2000, Double(i) * 1000)) }
        let route = RideSim.route(vertices)                 // ~220 km, ~22 000 points
        XCTAssertGreaterThan(route.points.count, 20_000)
        var sim = RideSim(seed: 1, sigma: 5)
        var m = RouteMatcher(route: route)
        let fixes = sim.ride(route, to: 300).map(\.fix)
        let start = Date()
        for fix in fixes { _ = m.update(fix) }
        let perFix = Date().timeIntervalSince(start) / Double(fixes.count)
        XCTAssertLessThan(perFix, 0.05)                     // debug build on a CI machine
    }
}

/// The matched engine end to end: `RideEngine` with the matcher, the guidance hooks and the ring commands.
final class MatchedEngineTests: XCTestCase {

    func engine(_ route: RouteGeometry, joinNearest: Bool = false) -> RideEngine {
        RideEngine(route: route, title: "Test", settings: .init(), joinNearest: joinNearest, engine: .matched)
    }

    /// A U-turn glyph (`nav` with step type 8).
    func isUTurn(_ c: NavCommand) -> Bool { c.label == "nav" && c.data.count > 5 && c.data[5] == 8 }

    func testStepAlongIsExactForGPXTurns() {
        let route = RideSim.route([(0, 0), (0, 400), (400, 400)])
        let e = engine(route)
        let along = try! XCTUnwrap(e.director?.stepAlong)
        XCTAssertEqual(along.count, e.director?.steps.count)
        XCTAssertEqual(along.first, 0)
        XCTAssertEqual(along[1], route.cumulative[40], accuracy: 0.01)   // the corner, point 40
        XCTAssertEqual(along.last ?? 0, route.length, accuracy: 0.01)
    }

    func testRideToArrivalWithNoise() {
        let route = RideSim.route([(0, 0), (0, 400), (400, 400)])
        for seed in 1...10 as ClosedRange<UInt64> {
            var sim = RideSim(seed: seed, sigma: 5)
            var e = engine(route)
            _ = e.start(ringConnected: true)
            var labels: [String] = []
            var arrived = false
            for (fix, _) in sim.ride(route) where !arrived {
                let r = e.update(fix)
                labels += r.commands.map(\.label)
                arrived = r.arrived
            }
            XCTAssertTrue(arrived, "seed \(seed)")
            XCTAssertTrue(labels.contains("navAngle"), "seed \(seed)")
            XCTAssertFalse(labels.contains("navPointer"), "seed \(seed)")
            XCTAssertEqual(e.director?.completed, true)
        }
    }

    func testShortcutMovesTheStepOn() {
        // North 300, east 300, south 300; the rider cuts straight across at 150 m.
        let route = RideSim.route([(0, 0), (0, 300), (300, 300), (300, 0)])
        let rider = RideSim.route([(0, 0), (0, 150), (300, 150), (300, 0)])
        var sim = RideSim(seed: 4, sigma: 5)
        var e = engine(route)
        var arrived = false
        var stepNearTheEnd: Int?
        for (fix, truth) in sim.ride(rider) where !arrived {
            arrived = e.update(fix).arrived
            if truth > rider.length - 80, stepNearTheEnd == nil { stepNearTheEnd = e.director?.guidance?.currentStepIndex }
        }
        XCTAssertEqual(stepNearTheEnd, 2)                   // past both corners
        XCTAssertTrue(arrived)
        XCTAssertFalse(e.snapshot.offRoute)
    }

    func testMissedTurnThenBackToIt() {
        // North 400 then east; the rider overshoots the corner by 100 m, comes back and turns.
        let route = RideSim.route([(0, 0), (0, 400), (400, 400)])
        let rider = RideSim.route([(0, 0), (0, 500), (0, 400), (400, 400)])
        for seed in 1...10 as ClosedRange<UInt64> {
            var sim = RideSim(seed: seed, sigma: 5)
            var e = engine(route)
            var arrived = false, wentOff = false
            for (fix, _) in sim.ride(rider) where !arrived {
                arrived = e.update(fix).arrived
                wentOff = wentOff || e.snapshot.offRoute
                XCTAssertNotEqual(e.snapshot.wrongWay, true, "seed \(seed)")
            }
            XCTAssertTrue(wentOff, "seed \(seed)")        // 100 m past the corner is off the route
            XCTAssertTrue(arrived, "seed \(seed)")
        }
    }

    func testLoopDoesNotEndAtItsStart() {
        let route = RideSim.route([(0, 0), (300, 0), (300, 300), (0, 300), (0, 0)])
        var sim = RideSim(seed: 2, sigma: 5)
        var e = engine(route)
        var arrivedAt: Double?
        for (fix, truth) in sim.ride(route) where arrivedAt == nil {
            if e.update(fix).arrived { arrivedAt = truth }
        }
        XCTAssertGreaterThan(arrivedAt ?? 0, route.length - 75)
    }

    /// Ride 400 m north on a straight route, then back south until the warning is confirmed.
    func rideBackwards(_ e: inout RideEngine, _ sim: inout RideSim, _ route: RouteGeometry) -> [NavCommand] {
        for (fix, _) in sim.ride(route, to: 400, speed: 5) { _ = e.update(fix) }
        var cmds: [NavCommand] = []
        for (fix, _) in sim.ride(route, from: 400, to: 200, speed: 5) {
            cmds += e.update(fix).commands
            if e.snapshot.wrongWay == true { break }
        }
        return cmds
    }

    func testWrongWayShowsTheUTurnOnTheRing() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        var sim = RideSim(seed: 5, sigma: 5)
        var e = engine(route)
        let cmds = rideBackwards(&e, &sim, route)
        XCTAssertEqual(e.snapshot.wrongWay, true)
        XCTAssertEqual(e.snapshot.canInvert, true)
        XCTAssertEqual(cmds.filter(isUTurn).count, 1)
        XCTAssertEqual(cmds.last.map { $0.label }, "sound")
        XCTAssertEqual(e.director?.carouselCard().data, Commands.carouselNavigationCard(
            mask: NavDirector.defaultCards | Commands.CarouselCard.navigation.bit, distance: 0, angle: 180,
            text: "Turn around", metric: true))
        // While it lasts, only the glyph.
        let (fix, _) = sim.ride(route, from: 190, to: 190, speed: 5)[0]
        let next = e.update(fix).commands
        XCTAssertEqual(next.count, 1)
        XCTAssertTrue(next.allSatisfy(isUTurn))
    }

    func testIgnoringClearsTheUTurn() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        var sim = RideSim(seed: 6, sigma: 5)
        var e = engine(route)
        _ = rideBackwards(&e, &sim, route)
        e.ignoreWrongWay()
        XCTAssertEqual(e.snapshot.wrongWay, false)
        let (fix, _) = sim.ride(route, from: 190, to: 190, speed: 5)[0]
        let cmds = e.update(fix).commands
        XCTAssertEqual(cmds.first?.label, "navOff")
        XCTAssertFalse(cmds.contains(where: isUTurn))
        XCTAssertEqual(e.snapshot.wrongWay, false)
    }

    func testInvertingCarriesOnTheRideTheOtherWay() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        var sim = RideSim(seed: 8, sigma: 5)
        var e = engine(route)
        _ = rideBackwards(&e, &sim, route)
        let ridden = e.snapshot.distanceRidden
        let inverted = try! XCTUnwrap(e.inverted())
        XCTAssertTrue(inverted.commands.map(\.label).contains("navOff"))
        e = inverted.engine
        XCTAssertEqual(e.snapshot.distanceRidden, ridden)
        XCTAssertGreaterThan(e.snapshot.progress, 0.7)              // ~350 m from the end of 1.5 km
        var labels: [String] = []
        var arrived = false
        for (fix, _) in sim.ride(route, from: 190, to: 0, speed: 5) where !arrived {
            let r = e.update(fix)
            labels += r.commands.map(\.label)
            arrived = r.arrived
            XCTAssertNotEqual(e.snapshot.wrongWay, true)
        }
        XCTAssertTrue(arrived)                              // at the original start
        XCTAssertFalse(labels.contains("navPointer"))       // no "Return to route" flash
    }

    func testRoutedDestinationCannotBeInverted() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        let e = RideEngine(route: route, title: "Test", settings: .init(),
                           instructions: [(NavLocation(41.39, 2.16), "Turn right")], engine: .matched)
        XCTAssertFalse(e.invertible)
        XCTAssertNil(e.inverted())
    }

    func testCompassHasNoMatcher() {
        let e = RideEngine(compassTo: RideSim.point(0, 1000), from: RideSim.point(0, 0), title: "Bar", settings: .init())
        XCTAssertNil(e.matcher)
        XCTAssertNil(e.snapshot.wrongWay)
    }

    // MARK: Trace

    func record(_ engineKind: RideEngine.Engine) -> (lines: [Data], commands: [[RideTrace.Command]]) {
        let route = RideSim.route([(0, 0), (0, 400), (400, 400)])
        var e = RideEngine(route: route, title: "Test", settings: .init(), engine: engineKind)
        var lines = [RideTrace.line(RideTrace.Header(engine: e, title: "Test"))!]
        var commands: [[RideTrace.Command]] = []
        var sim = RideSim(seed: 9, sigma: 5)
        for (fix, _) in sim.ride(route) {
            let r = e.update(fix)
            lines.append(RideTrace.line(RideTrace.Entry(fix: fix, engine: e, commands: r.commands, arrived: r.arrived))!)
            commands.append(r.commands.map(RideTrace.Command.init))
            if r.arrived { break }
        }
        return (lines, commands)
    }

    func testReplayReproducesBothEngines() throws {
        for kind in [RideEngine.Engine.classic, .matched] {
            let rec = record(kind)
            let summary = try RideReplay.run(rec.lines.map { $0.dropLast() })
            XCTAssertEqual(summary.commands, rec.commands, "\(kind)")
            XCTAssertEqual(summary.arrivedAt, rec.commands.count - 1, "\(kind)")
        }
    }

    func testClassicTraceHasNoMatchedKeys() throws {
        let rec = record(.classic)
        let header = String(decoding: rec.lines[0], as: UTF8.self)
        let entry = String(decoding: rec.lines[1], as: UTF8.self)
        XCTAssertFalse(header.contains("\"engine\""))
        XCTAssertFalse(entry.contains("\"match\""))
        XCTAssertFalse(entry.contains("wrongWay"))
        XCTAssertTrue(String(decoding: record(.matched).lines[1], as: UTF8.self).contains("\"match\""))
    }
}
