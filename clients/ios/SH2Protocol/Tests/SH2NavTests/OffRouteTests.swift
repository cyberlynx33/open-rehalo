import XCTest
@testable import SH2Nav

/// Off the route and back (docs/APP_SPEC.md M17): the matcher's hysteresis, the GPS quality gate, the
/// reroute back-off and the splice of a leg back onto the route.
final class OffRouteTests: XCTestCase {

    let seeds: [UInt64] = Array(1...10)
    let p = RouteMatcher.Parameters()

    /// A rider on a 1 km straight who, at `at` metres, turns off at `angle` degrees (90 = square off)
    /// and rides `legLength` metres away: the true distance along their own path when the matcher first
    /// said off, and the distance from the route then.
    func leaves(angle: Double, legLength: Double = 400, seed: UInt64) -> (offAt: Double?, offDistance: Double?) {
        let route = RideSim.route([(0, 0), (0, 1000)])
        let rad = angle * .pi / 180
        let rider = RideSim.route([(0, 0), (0, 300), (legLength * sin(rad), 300 + legLength * cos(rad))])
        var sim = RideSim(seed: seed, sigma: 5)
        var m = RouteMatcher(route: route)
        for (fix, truth) in sim.ride(rider) {
            let r = m.update(fix)
            if r.status == .off, m.last.joined { return (truth, r.distanceToRoute) }
        }
        return (nil, nil)
    }

    /// Square off the route: 2 fixes heading away past 50 m + accuracy, well before the 4 s far rule.
    func testTurningOffTheRouteLeavesItOnTwoFixesHeadingAway() {
        for seed in seeds {
            let r = leaves(angle: 90, seed: seed)
            XCTAssertNotNil(r.offAt, "seed \(seed)")
            // Past 55 m from the route at 5.5 m/s: the next fix confirms. Under 80 m away when it does.
            if let d = r.offDistance { XCTAssertLessThan(d, 80, "seed \(seed)") }
            if let at = r.offAt { XCTAssertLessThan(at, 300 + 80, "seed \(seed)") }
        }
    }

    /// Drifting off at 30° (within `leaveHeadingAngle`): the far rule alone, 60 m + accuracy for 4 s.
    func testDriftingOffTheRouteLeavesItAfterTheWaitFarFromIt() {
        for seed in seeds {
            let r = leaves(angle: 30, legLength: 600, seed: seed)
            XCTAssertNotNil(r.offAt, "seed \(seed)")
            // 65 m from the route is 130 m along the 30° leg; then `leaveSeconds` more.
            if let at = r.offAt {
                XCTAssertGreaterThan(at, 300 + 130 + p.leaveSeconds * 5.5 - 35, "seed \(seed)")
                XCTAssertLessThan(at, 300 + 130 + (p.leaveSeconds + 5) * 5.5, "seed \(seed)")
            }
            if let d = r.offDistance { XCTAssertGreaterThan(d, p.leaveDistance, "seed \(seed)") }
        }
    }

    /// Off and back: on again `rejoinSeconds` after being within 20 m + accuracy of the route.
    func testBackOnTheRouteTakesTenSeconds() {
        let route = RideSim.route([(0, 0), (0, 1500)])
        let rider = RideSim.route([(0, 0), (0, 300), (150, 450), (150, 600), (0, 750), (0, 1500)])
        for seed in seeds {
            var sim = RideSim(seed: seed, sigma: 5)
            var m = RouteMatcher(route: route)
            var offAt: Double?, backAt: Double?, nearAt: Double?
            for (fix, truth) in sim.ride(rider) {
                let r = m.update(fix)
                if r.status == .off, offAt == nil, m.last.joined { offAt = truth }
                if offAt != nil, nearAt == nil, r.distanceToRoute < p.rejoinDistance + sim.accuracy { nearAt = truth }
                if nearAt != nil, backAt == nil, r.status == .on { backAt = truth }
            }
            XCTAssertNotNil(offAt, "seed \(seed)")
            XCTAssertNotNil(backAt, "seed \(seed)")
            // A noisy fix outside the rejoin distance starts the wait over: a little longer at times.
            if let near = nearAt, let back = backAt {
                XCTAssertGreaterThanOrEqual(back - near, (p.rejoinSeconds - 1) * 5.5, "seed \(seed)")
                XCTAssertLessThan(back - near, (p.rejoinSeconds + 8) * 5.5, "seed \(seed)")
            }
        }
    }

    // MARK: - GPS quality

    let lat0 = 41.39, lon0 = 2.16
    func point(north: Double, east: Double) -> GeoPoint {
        GeoPoint(lat0 + north / 111_195, lon0 + east / (111_195 * cos(lat0 * .pi / 180)))
    }

    func straight() -> RouteGeometry {
        RouteGeometry(points: (0...100).map { point(north: Double($0) * 10, east: 0) })
    }

    func testWeakThenLostGPSWithoutAGoodFix() {
        var e = RideEngine(route: straight(), title: "Test", settings: .init())
        _ = e.update(RideFix(lat: point(north: 0, east: 0).lat, lon: point(north: 0, east: 0).lon, speed: 5, time: 0))
        XCTAssertEqual(e.snapshot.gpsQuality, .good)
        // Bad fixes keep coming: weak at 30 s, lost at 60 s, and the ring gets nothing from them.
        var qualities: [GPSQuality] = []
        for t in stride(from: 5.0, through: 65, by: 5) {
            let p = point(north: t * 5, east: 0)
            let r = e.update(RideFix(lat: p.lat, lon: p.lon, horizontalAccuracy: 90, speed: 5, time: t))
            XCTAssertTrue(r.commands.isEmpty, "t \(t)")
            qualities.append(e.snapshot.gpsQuality ?? .good)
        }
        XCTAssertEqual(qualities[0], .good)                     // 5 s
        XCTAssertEqual(qualities[4], .good)                     // 25 s
        XCTAssertEqual(qualities[5], .weak)                     // 30 s
        XCTAssertEqual(qualities[10], .weak)                    // 55 s
        XCTAssertEqual(qualities[11], .lost)                    // 60 s
        XCTAssertEqual(e.gpsQuality(at: 200), .lost)
        // A good fix brings it back.
        let p = point(north: 350, east: 0)
        _ = e.update(RideFix(lat: p.lat, lon: p.lon, horizontalAccuracy: 10, speed: 5, time: 70))
        XCTAssertEqual(e.snapshot.gpsQuality, .good)
    }

    func testTheClockAloneSaysWeakWhenFixesStop() {
        var e = RideEngine(route: straight(), title: "Test", settings: .init())
        XCTAssertEqual(e.gpsQuality(at: 1_000), .good)          // nothing yet: "Waiting for GPS…"
        let p = point(north: 0, east: 0)
        _ = e.update(RideFix(lat: p.lat, lon: p.lon, speed: 5, time: 100))
        XCTAssertEqual(e.gpsQuality(at: 129), .good)
        XCTAssertEqual(e.gpsQuality(at: 130), .weak)
        XCTAssertEqual(e.gpsQuality(at: 160), .lost)
    }

    // MARK: - Reroute back-off

    func testBackoffDoublesFromThirtySecondsToEightMinutes() {
        XCTAssertEqual((1...7).map(RerouteBackoff.delay(afterFailures:)), [30, 60, 120, 240, 480, 480, 480])
        var b = RerouteBackoff()
        XCTAssertTrue(b.canAttempt(at: 0))
        b.failed(at: 100)
        XCTAssertFalse(b.canAttempt(at: 129))
        XCTAssertTrue(b.canAttempt(at: 130))
        b.failed(at: 130)
        XCTAssertFalse(b.canAttempt(at: 189))
        XCTAssertTrue(b.canAttempt(at: 190))
        b.reset()
        XCTAssertEqual(b.failures, 0)
        XCTAssertTrue(b.canAttempt(at: 0))
    }

    // MARK: - Splicing a leg back onto the route

    func testTheRouteFromAPointOnKeepsItsElevation() throws {
        let route = RouteGeometry(points: (0...10).map { point(north: Double($0) * 100, east: 0) },
                                  elevations: (0...10).map { Double($0) * 10 })
        let rest = try XCTUnwrap(route.suffix(from: 250))
        XCTAssertEqual(rest.points.count, 9)                   // the cut, then 300…1000
        XCTAssertEqual(rest.length, route.length - 250, accuracy: 0.5)
        XCTAssertNil(rest.elevations[0])
        XCTAssertEqual(rest.elevations[1], 30)
        XCTAssertEqual(route.suffix(from: 0)?.points.count, 11)
        XCTAssertNil(route.suffix(from: route.length))
    }

    func testTypedStepsAreCutAtTheRejoin() throws {
        let a = [point(north: 0, east: 0), point(north: 300, east: 0)]
        let b = [point(north: 300, east: 0), point(north: 300, east: 300)]
        let c = [point(north: 300, east: 300), point(north: 600, east: 300)]
        let steps = [RoutedStep(points: a, text: "", maneuver: .depart),
                     RoutedStep(points: b, text: "", maneuver: .right),
                     RoutedStep(points: c, text: "", maneuver: .left),
                     RoutedStep(points: [c[1], c[1]], text: "", maneuver: .arrive)]
        let rest = try XCTUnwrap(RoutedStep.suffix(steps, from: 450))
        XCTAssertEqual(rest.count, 3)
        XCTAssertNil(rest[0].maneuver)                          // the turn at its start is behind
        XCTAssertEqual(rest[0].length, 150, accuracy: 1)
        XCTAssertEqual(rest[1].maneuver, .left)
        XCTAssertNil(RoutedStep.suffix(steps, from: 2000))
    }

    /// Off the route on a routed ride, a BRouter leg back to it 300 m ahead: the new ride is the leg
    /// plus what is left, with the leg's typed steps and the route's remaining ones.
    func testAReroutedRideIsTheLegPlusTheRest() throws {
        let a = (0...30).map { point(north: Double($0) * 10, east: 0) }
        let b = (1...30).map { point(north: 300, east: Double($0) * 10) }
        let steps = [RoutedStep(points: a, text: "", maneuver: .depart),
                     RoutedStep(points: b, text: "", maneuver: .right),
                     RoutedStep(points: [b[29], b[29]], text: "", maneuver: .arrive)]
        let route = RouteGeometry(points: a + b)
        var e = RideEngine(route: route, title: "Office", settings: .init(), routedSteps: steps, engine: .matched)
        XCTAssertEqual(e.director?.routed, true)
        var t = 0.0
        for along in stride(from: 0.0, through: 100, by: 5) {
            let q = route.coordinate(at: along)
            _ = e.update(RideFix(lat: q.lat, lon: q.lon, speed: 5, time: t)); t += 1
        }
        // The rider wanders off east from (100, 0) to (100, 150).
        for east in stride(from: 5.0, through: 150, by: 5) {
            let q = point(north: 100, east: east)
            _ = e.update(RideFix(lat: q.lat, lon: q.lon, speed: 5, time: t)); t += 1
        }
        XCTAssertTrue(e.snapshot.offRoute)
        let rejoin = e.rerouteRejoinAlong
        XCTAssertEqual(rejoin, 100 + RideEngine.rerouteRejoinAhead, accuracy: 30)
        let target = route.coordinate(at: rejoin)
        let leg = RouteGeometry(points: [point(north: 100, east: 150), point(north: 300, east: 150), target])
        let legSteps = [RoutedStep(points: [leg.points[0], leg.points[1]], text: "", maneuver: .depart),
                        RoutedStep(points: [leg.points[1], leg.points[2]], text: "", maneuver: .left),
                        RoutedStep(points: [target, target], text: "", maneuver: .arrive)]
        let r = try XCTUnwrap(e.rerouted(onto: leg, legSteps: legSteps, rejoinAlong: rejoin))
        XCTAssertFalse(r.commands.isEmpty)                      // the ring is cleared first
        XCTAssertEqual(r.engine.route.points.first, leg.points[0])
        XCTAssertEqual(r.engine.route.points.last, route.points.last)
        XCTAssertEqual(r.engine.route.length, leg.length + (route.length - rejoin), accuracy: 1)
        XCTAssertEqual(r.engine.director?.routed, true)        // typed steps all the way
        XCTAssertEqual(r.engine.snapshot.distanceRidden, e.snapshot.distanceRidden)
        XCTAssertEqual(r.engine.snapshot.progress, 0)
        // Riding the leg: on the route from its start, the left turn onto the old route announced.
        var ride = r.engine
        var kinds: Set<TurnKind> = []
        for north in stride(from: 100.0, through: 290, by: 5) {
            let q = point(north: north, east: 150)
            _ = ride.update(RideFix(lat: q.lat, lon: q.lon, speed: 5, time: t)); t += 1
            kinds.insert(ride.snapshot.nextTurn)
        }
        XCTAssertFalse(ride.snapshot.offRoute)
        XCTAssertTrue(kinds.contains(.left))
    }
}
