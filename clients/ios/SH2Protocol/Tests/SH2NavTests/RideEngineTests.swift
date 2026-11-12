import XCTest
@testable import SH2Nav

/// `RideEngine` driven with synthetic rides: the screen says what the ring guidance says.
final class RideEngineTests: XCTestCase {

    let lat0 = 41.39, lon0 = 2.16
    func point(north: Double, east: Double) -> GeoPoint {
        GeoPoint(lat0 + north / 111_195, lon0 + east / (111_195 * cos(lat0 * .pi / 180)))
    }

    /// 400 m north, then 400 m east (a right turn), a point every 10 m.
    func lRoute() -> RouteGeometry {
        RouteGeometry(points: (0...40).map { point(north: Double($0) * 10, east: 0) }
                              + (1...40).map { point(north: 400, east: Double($0) * 10) })
    }

    func engine(_ route: RouteGeometry) -> RideEngine {
        RideEngine(route: route, title: "Test", settings: .init())
    }

    func fix(_ p: GeoPoint, t: Double, speed: Double = 5, accuracy: Double = 5) -> RideFix {
        RideFix(lat: p.lat, lon: p.lon, horizontalAccuracy: accuracy, speed: speed, time: t)
    }

    /// Ride along `route` from `from` to `to` metres at 5 m/s.
    func ride(_ e: inout RideEngine, _ route: RouteGeometry, from: Double, to: Double) -> Bool {
        var along = from, t = from / 5
        while along <= to {
            if e.update(fix(route.coordinate(at: along), t: t)).arrived { return true }
            along += 5; t += 1
        }
        return false
    }

    func testStartsAtTheFirstManoeuvre() {
        let route = lRoute()
        let e = engine(route)
        XCTAssertEqual(e.snapshot.remainingDistance, route.length, accuracy: 0.01)
        XCTAssertEqual(e.snapshot.nextTurn, .right)
        XCTAssertEqual(e.snapshot.nextTurnDistance, 400, accuracy: 15)
        XCTAssertEqual(e.snapshot.heading, 0, accuracy: 1)
        XCTAssertFalse(e.snapshot.reachedOrigin)
    }

    func testRideToArrival() {
        let route = lRoute()
        var e = engine(route)
        XCTAssertFalse(ride(&e, route, from: 0, to: 300))
        XCTAssertEqual(e.snapshot.progress, 300 / route.length, accuracy: 0.02)
        XCTAssertFalse(e.snapshot.offRoute)
        XCTAssertEqual(e.snapshot.fixCount, 61)
        XCTAssertEqual(e.snapshot.distanceRidden, 300, accuracy: 5)
        XCTAssertTrue(ride(&e, route, from: 300, to: route.length))
        XCTAssertTrue(e.director?.completed == true)
        XCTAssertTrue(e.stop().isEmpty)                // arrival already cleared the ring
    }

    func testScreenAndRingAgreeOnTheNextTurn() {
        let route = lRoute()
        var e = engine(route)
        XCTAssertFalse(ride(&e, route, from: 0, to: 340))
        let ring = e.director?.guidance?.display
        XCTAssertEqual(ring?.thisTurn.relativeTurnAngle, 90)
        XCTAssertEqual(e.snapshot.nextTurn, .right)
        XCTAssertEqual(e.snapshot.nextTurnDistance, Double(ring?.distanceToThisManeuver ?? -1))
        XCTAssertEqual(e.snapshot.nextTurnDistance, 35, accuracy: 15)   // 25 m short of the corner
    }

    func testScreenFollowsTheRingOffTheRouteAndBack() {
        let route = lRoute()
        var e = engine(route)
        XCTAssertFalse(ride(&e, route, from: 0, to: 200))
        XCTAssertTrue(e.snapshot.reachedOrigin)
        for (i, east) in [10.0, 30, 60, 100, 140].enumerated() {
            _ = e.update(fix(point(north: 200 + Double(i) * 2, east: east), t: 50 + Double(i)))
        }
        XCTAssertTrue(e.snapshot.offRoute)
        XCTAssertEqual(e.snapshot.offRoute, e.director?.guidance?.offlineStatus != .onPath)
        XCTAssertEqual(e.snapshot.offRouteDistance, 140, accuracy: 10)
        XCTAssertNotNil(e.snapshot.offRouteBearing)
        _ = e.update(fix(point(north: 215, east: 0), t: 60))
        XCTAssertFalse(e.snapshot.offRoute)
    }

    func testHeadingForTheStartIsOffRoute() {
        let route = lRoute()
        var e = engine(route)
        _ = e.update(fix(point(north: -100, east: 0), t: 0))
        XCTAssertTrue(e.snapshot.offRoute)
        XCTAssertFalse(e.snapshot.reachedOrigin)
    }

    func testStreetNameReachesTheScreen() {
        let route = lRoute()
        let corner = point(north: 400, east: 0)
        var e = RideEngine(route: route, title: "Test", settings: .init(),
                           instructions: [(location: NavLocation(corner.lat, corner.lon), text: "Carrer Major")])
        XCTAssertFalse(ride(&e, route, from: 0, to: 100))
        XCTAssertEqual(e.snapshot.nextTurnText, "Carrer Major")
    }

    func testOffRouteFreezesTheProgress() {
        let route = lRoute()
        var e = engine(route)
        XCTAssertFalse(ride(&e, route, from: 0, to: 200))
        let progress = e.snapshot.progress
        _ = e.update(fix(point(north: 205, east: 60), t: 50))
        _ = e.update(fix(point(north: 210, east: 100), t: 51))
        XCTAssertTrue(e.snapshot.offRoute)
        XCTAssertEqual(e.snapshot.progress, progress, accuracy: 0.03)
    }

    func testGPSJumpsDoNotCountAsDistance() {
        let route = lRoute()
        var e = engine(route)
        _ = e.update(fix(point(north: 0, east: 0), t: 0))
        _ = e.update(fix(point(north: 1000, east: 0), t: 1))
        XCTAssertEqual(e.snapshot.distanceRidden, 0)
    }

    func testBadFixesDoNotCountAsDistanceButStillReachTheScreen() {
        let route = lRoute()
        var e = engine(route)
        _ = e.update(fix(point(north: 0, east: 0), t: 0))
        _ = e.update(fix(point(north: 100, east: 0), t: 1, accuracy: 80))
        XCTAssertEqual(e.snapshot.distanceRidden, 0)
        XCTAssertEqual(e.snapshot.progress, 100 / route.length, accuracy: 0.01)
    }

    func testSpeedFallsBackToDistanceOverTime() {
        let route = lRoute()
        var e = engine(route)
        _ = e.update(fix(point(north: 0, east: 0), t: 0, speed: -1))
        XCTAssertNil(e.snapshot.speed)
        _ = e.update(fix(point(north: 12, east: 0), t: 2, speed: -1))
        XCTAssertEqual(e.snapshot.speed ?? 0, 6, accuracy: 0.1)
    }

    func testLeadInCountsDownToTheStart() {
        let lead = RouteGeometry(points: (0...20).map { point(north: 0, east: Double(-200 + $0 * 10)) })
        let route = RouteGeometry(points: (0...40).map { point(north: Double($0) * 10, east: 0) })
        let chained = RouteGeometry.chain(lead, before: route)
        var e = RideEngine(route: chained, title: "Test", settings: .init(), leadInLength: lead.length)
        XCTAssertEqual(e.snapshot.toStart ?? 0, 200, accuracy: 1)
        XCTAssertFalse(ride(&e, chained, from: 0, to: 100))
        XCTAssertEqual(e.snapshot.toStart ?? 0, 100, accuracy: 1)
        XCTAssertFalse(ride(&e, chained, from: 100, to: 195))
        XCTAssertNil(e.snapshot.toStart)
    }

    func testChainDropsTheSharedPoint() {
        let a = RouteGeometry(points: [point(north: 0, east: -10), point(north: 0, east: 0)])
        let b = RouteGeometry(points: [point(north: 0, east: 0), point(north: 10, east: 0)])
        XCTAssertEqual(RouteGeometry.chain(a, before: b).points.count, 3)
    }

    func testCompassTracksTheDestination() {
        let target = point(north: 1000, east: 0)
        var e = RideEngine(compassTo: target, from: point(north: 0, east: 0), title: "X", settings: .init())
        _ = e.update(fix(point(north: 0, east: 0), t: 0, speed: 0))
        XCTAssertEqual(e.snapshot.remainingDistance, 1000, accuracy: 5)
        XCTAssertEqual(e.snapshot.nextTurn, .straight)
        _ = e.update(fix(point(north: 500, east: 0), t: 1, speed: 0))
        XCTAssertEqual(e.snapshot.progress, 0.5, accuracy: 0.01)
    }

    func testCompassHeadingOnlyWhenSlow() {
        let target = point(north: 1000, east: 0)
        var e = RideEngine(compassTo: target, from: nil, title: "X", settings: .init())
        var slow = fix(point(north: 0, east: 0), t: 0, speed: 0)
        slow.course = -1
        _ = e.update(slow, compassHeading: 90)
        XCTAssertEqual(e.snapshot.heading, 90)
        XCTAssertEqual(e.snapshot.compassBearing, -90, accuracy: 1)
    }

    func testRepeatableRide() {
        let route = lRoute()
        var a = engine(route), b = engine(route)
        XCTAssertFalse(ride(&a, route, from: 0, to: 500))
        XCTAssertFalse(ride(&b, route, from: 0, to: 500))
        XCTAssertEqual(a.snapshot, b.snapshot)
    }

    // MARK: - Trace

    func testTraceLineIsSortedAndComplete() throws {
        let route = lRoute()
        var e = engine(route)
        let intro = e.start(ringConnected: true)
        XCTAssertEqual(intro.map(\.label), ["turnByTurnIntro", "carouselPosition"])
        let f = fix(route.coordinate(at: 0), t: 0)
        let r = e.update(f)
        let entry = RideTrace.Entry(fix: f, engine: e, commands: r.commands, arrived: r.arrived)
        let line = try XCTUnwrap(RideTrace.line(entry))
        XCTAssertEqual(line.last, 0x0a)
        let decoded = try JSONDecoder().decode(RideTrace.Entry.self, from: line.dropLast())
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(entry.ring?.status, "onPath")
    }

    // MARK: - GPX

    let gpx = """
    <?xml version="1.0"?><gpx>
    <wpt lat="41.5" lon="2.5"><name>Fuente</name></wpt>
    <trk><name>Ruta</name><trkseg>
    <trkpt lat="41.1" lon="2.1"><ele>100</ele></trkpt>
    <trkpt lat="41.2" lon="2.2"><ele>110</ele></trkpt>
    </trkseg></trk></gpx>
    """

    func testGPXRouteIsTheTrackNotItsPointsOfInterest() throws {
        let f = try GPXFile.parse(data: Data(gpx.utf8))
        XCTAssertEqual(f.name, "Ruta")                 // the track's name, not a waypoint's
        XCTAssertEqual(f.points, [GeoPoint(41.1, 2.1), GeoPoint(41.2, 2.2)])
        XCTAssertEqual(f.navPoints, f.points)
        XCTAssertEqual(f.elevations, [100, 110])
    }

    func testGPXNamePrefersTheTrackThenTheFileOverAnyOther() throws {
        let metadata = try GPXFile.parse(data: Data("""
        <gpx><metadata><author><name>Ann</name></author><name>Sunday ride</name></metadata>
        <trk><trkseg><trkpt lat="41.1" lon="2.1"/><trkpt lat="41.2" lon="2.2"/></trkseg></trk></gpx>
        """.utf8))
        XCTAssertEqual(metadata.name, "Sunday ride")
        let track = try GPXFile.parse(data: Data("""
        <gpx><metadata><name>Sunday ride</name></metadata>
        <trk><name>Ruta</name><trkseg><trkpt lat="41.1" lon="2.1"/><trkpt lat="41.2" lon="2.2"/></trkseg></trk></gpx>
        """.utf8))
        XCTAssertEqual(track.name, "Ruta")
    }

    func testGPXWithPrefixedElementsIsRead() throws {
        let f = try GPXFile.parse(data: Data("""
        <gpx:gpx xmlns:gpx="http://www.topografix.com/GPX/1/1" version="1.1">
        <gpx:trk><gpx:name>Prefixed</gpx:name><gpx:trkseg>
        <gpx:trkpt lat="41.1" lon="2.1"><gpx:ele>7</gpx:ele></gpx:trkpt>
        <gpx:trkpt lat="41.2" lon="2.2"/>
        </gpx:trkseg></gpx:trk></gpx:gpx>
        """.utf8))
        XCTAssertEqual(f.name, "Prefixed")
        XCTAssertEqual(f.points, [GeoPoint(41.1, 2.1), GeoPoint(41.2, 2.2)])
        XCTAssertEqual(f.elevations, [7, nil])
    }

    func testMalformedGPXSaysSo() {
        let truncated = Data("""
        <gpx><trk><trkseg><trkpt lat="41.1" lon="2.1"/><trkpt lat="41.2" lon="2.2"/></trkseg>
        """.utf8)
        XCTAssertThrowsError(try GPXFile.parse(data: truncated)) { error in
            guard case GPXError.malformed = error else { return XCTFail("\(error)") }
        }
    }

    func testGPXPlannedRouteAloneIsNavigable() throws {
        let f = try GPXFile.parse(data: Data("""
        <gpx><rte><rtept lat="41.1" lon="2.1"/><rtept lat="41.2" lon="2.2"><ele>5</ele></rtept></rte>
        <wpt lat="41.5" lon="2.5"/></gpx>
        """.utf8))
        XCTAssertEqual(f.points, [GeoPoint(41.5, 2.5)])  // waypoints win over a planned route when alone
    }

    func testGPXWithoutPointsFails() {
        XCTAssertThrowsError(try GPXFile.parse(data: Data("<gpx></gpx>".utf8)))
    }
}
