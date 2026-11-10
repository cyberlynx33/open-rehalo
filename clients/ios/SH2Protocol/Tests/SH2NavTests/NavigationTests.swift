import XCTest
@testable import SH2Nav

/// The reimplementation of the official app's GPX navigation (`Navigation/`), driven with synthetic rides.
final class NavigationTests: XCTestCase {

    // Montréal-ish origin; metres → degrees.
    let lat0 = 45.5, lon0 = -73.6
    func point(north: Double, east: Double, accuracy: Int = 5) -> NavLocation {
        NavLocation(lat0 + north / 111_320,
                    lon0 + east / (111_320 * cos(lat0 * .pi / 180)), accuracy: accuracy)
    }

    /// 200 m north, then 200 m east (a right turn), a point every 10 m.
    func lRoute() -> [NavLocation] {
        (0...20).map { point(north: Double($0) * 10, east: 0, accuracy: 0) }
            + (1...20).map { point(north: 200, east: Double($0) * 10, accuracy: 0) }
    }

    // MARK: - Geometry

    func testAngleHelpers() {
        XCTAssertEqual(NavMath.difference(170, -170), 20)
        XCTAssertEqual(NavMath.difference(0, 270), -90)
        XCTAssertEqual(NavMath.gap(360, 0), 360)
        XCTAssertEqual(NavMath.smallerGap(-170, 170), 20)
        XCTAssertEqual(NavMath.normalized(540), 180)
        XCTAssertEqual(NavMath.normalized(-190), 170)
    }

    func testBearingIsRoundedAndSigned() {
        let a = point(north: 0, east: 0)
        XCTAssertEqual(a.bearing(to: point(north: 100, east: 0)), 0)
        XCTAssertEqual(a.bearing(to: point(north: 0, east: 100)), 90)
        XCTAssertEqual(a.bearing(to: point(north: 0, east: -100)), -90)
        XCTAssertEqual(a.bearing(to: a), 180)                      // same point → 180, as the original
        XCTAssertEqual(a.distance(to: point(north: 100, east: 0)), 100, accuracy: 0.5)
    }

    // MARK: - Direction of travel

    func testRiderDirectionNeedsThreeSamplesFarEnoughApart() {
        var b = NavBearing()
        b.previousLocation = point(north: 0, east: 0)
        for i in 1...2 { b.update(point(north: 0, east: Double(i) * 5)) }
        XCTAssertEqual(b.current, NavBearing.unknown)              // 2 samples only
        b.update(point(north: 0, east: 15))
        XCTAssertEqual(b.current, 90)
        XCTAssertEqual(b.crowFlies, 90)

        // Fixes 3 m apart (< 3.5 m) never make samples.
        var slow = NavBearing()
        slow.previousLocation = point(north: 0, east: 0)
        for i in 1...10 { slow.update(point(north: Double(i) * 3, east: 0)) }
        XCTAssertEqual(slow.current, NavBearing.unknown)

        // Inaccurate fixes (≥ 35 m) are ignored too.
        var bad = NavBearing()
        bad.previousLocation = point(north: 0, east: 0, accuracy: 40)
        for i in 1...5 { bad.update(point(north: Double(i) * 10, east: 0, accuracy: 40)) }
        XCTAssertEqual(bad.current, NavBearing.unknown)
    }

    // MARK: - GPX → steps

    func testRightTurnSplitsTheRoute() {
        let steps = NavStepFactory.steps(from: lRoute())
        XCTAssertEqual(steps.map(\.type), [15, 15, 0])
        XCTAssertEqual(steps[0].instruction, "nav.inject.continue.instruction")
        XCTAssertEqual(steps[1].instruction, "nav.found.right")
        XCTAssertEqual(steps[1].angles, [90])
        XCTAssertEqual(steps[1].headingBefore, 0)
        XCTAssertEqual(steps[1].headingAfter, 90)
        XCTAssertEqual(steps[1].entrance, point(north: 200, east: 0, accuracy: 0))
        XCTAssertEqual(steps[2].instruction, "nav.inject.direct.arrival")
        XCTAssertEqual(steps[2].entrance, point(north: 200, east: 200, accuracy: 0))
    }

    func testStraightRouteHasNoTurns() {
        let line = (0...20).map { point(north: Double($0) * 10, east: 0) }
        let steps = NavStepFactory.steps(from: line)
        XCTAssertEqual(steps.map(\.type), [15, 0])
        XCTAssertEqual(steps[0].firstDistance, 0)                  // original quirk: no split → 0
    }

    func testWaypointsOnlyWinWhenMoreNumerous() {
        let w = [point(north: 0, east: 0)], t = [point(north: 1, east: 0), point(north: 2, east: 0)]
        XCTAssertEqual(NavStepFactory.points(waypoints: w, trackPoints: t), t)
        XCTAssertEqual(NavStepFactory.points(waypoints: t, trackPoints: w), t)
        XCTAssertEqual(NavStepFactory.points(waypoints: t, trackPoints: t), t)
    }

    // MARK: - A whole ride

    /// Ride the L at 5 m/s, 1 fix per second, from its start.
    func testRideOnTheRoute() {
        var director = NavDirector(points: lRoute(), title: "Office")
        let intro = director.start(ringConnected: true)
        XCTAssertEqual(intro.map(\.label), ["turnByTurnIntro", "carouselPosition"])

        var labels: [String] = []
        var angles: [[UInt8]] = []
        var arrived = false
        var fixes = (0...40).map { point(north: Double($0) * 5, east: 0) }
        fixes += (1...40).map { point(north: 200, east: Double($0) * 5) }
        for fix in fixes {
            let r = director.update(fix)
            labels += r.commands.map(\.label)
            angles += r.commands.filter { $0.label == "navAngle" }.map { [UInt8]($0.data) }
            if r.arrived { arrived = true; break }
        }
        // Starting on the route: no pointer, the right-turn arc as the corner nears, then arrival.
        XCTAssertFalse(labels.contains("navPointer"))
        XCTAssertFalse(angles.isEmpty)
        XCTAssertEqual(Array(angles[0][5...6]), [0x00, 0x5a])      // +90° = right
        XCTAssertEqual(angles[0][2], 67)                           // green
        XCTAssertTrue(arrived)
        XCTAssertTrue(director.completed)
        XCTAssertEqual(labels.suffix(3), ["sound", "nav", "navOff"])
    }

    /// A turn done, the Navigation card it refreshes is already the next turn's: the original reads
    /// the library's state after the fix (`updateState`, then `stopNavCommandOnSmartHalo`).
    func testCardAfterATurnShowsTheNextTurn() {
        var route: [NavLocation] = (0...20).map { point(north: Double($0) * 10, east: 0, accuracy: 0) }
        route += (1...30).map { point(north: 200, east: Double($0) * 10, accuracy: 0) }
        route += (1...30).map { point(north: 200 + Double($0) * 10, east: 300, accuracy: 0) }
        var director = NavDirector(points: route, title: "Office")
        _ = director.start(ringConnected: true)
        director.carouselOnNavigation = true
        var fixes: [NavLocation] = (0...40).map { point(north: Double($0) * 5, east: 0) }
        fixes += (1...50).map { point(north: 200, east: Double($0) * 5) }
        var cards: [[UInt8]] = []
        for fix in fixes {
            cards += director.update(fix).commands.filter { $0.label == "carousel" }.map { [UInt8]($0.data) }
        }
        guard let card = cards.last, cards.count >= 2 else { return XCTFail("no card after the turn") }
        let distance = Int(card[10]) | Int(card[9]) << 8 | Int(card[8]) << 16 | Int(card[7] & 0x7f) << 24
        let angle = Int(Int16(bitPattern: UInt16(card[11]) << 8 | UInt16(card[12])))
        XCTAssertEqual(angle, -90)                                 // the left turn ahead, not the right one done
        XCTAssertGreaterThan(distance, 0)
    }

    /// Start 200 m west of the route's start, riding towards it: "ride to calibrate" until the
    /// direction of travel is known, then the orange pointer straight ahead (arcs from 95 m), then
    /// guidance on the route.
    func testRideToTheStartOfTheRoute() {
        var director = NavDirector(points: lRoute(), title: "Office")
        _ = director.start(ringConnected: true)
        var first: [NavCommand] = []
        var pointers: [[UInt8]] = []
        for i in 0...45 {
            let r = director.update(point(north: 0, east: -200 + Double(i) * 5))
            if i == 0 { first = r.commands }
            pointers += r.commands.filter { $0.label == "navPointer" }.map { [UInt8]($0.data) }
        }
        XCTAssertEqual(first.map(\.label), ["navPointerStandby"])
        XCTAssertFalse(pointers.isEmpty)
        let p = pointers[0]
        XCTAssertEqual(Array(p[2...4]), [30, 255, 255])            // off-path orange
        let angle = Int(Int16(bitPattern: UInt16(p[5]) << 8 | UInt16(p[6])))
        XCTAssertLessThanOrEqual(abs(angle), 5)                    // dead ahead
        XCTAssertEqual(director.guidance?.hasReachedOrigin, true)
    }

    // MARK: - Routed destinations (not in the official app)

    /// A routed destination's instruction near the corner replaces "Turn right" on the OLED.
    func testRoutedTurnShowsItsInstruction() {
        var director = NavDirector(points: lRoute(), title: "Office",
                                   instructions: [(point(north: 0, east: 0), "Carrer Major"),
                                                  (point(north: 195, east: 3), "Av. Catalunya")])
        XCTAssertEqual(director.turnTexts, [1: "Av. Catalunya"])
        _ = director.start(ringConnected: true)
        var texts: [String] = []
        for i in 0...40 {
            let r = director.update(point(north: Double(i) * 5, east: 0))
            texts += r.commands.filter { $0.label == "navAngle" }.map { String(decoding: $0.data, as: UTF8.self) }
        }
        XCTAssertFalse(texts.isEmpty)
        XCTAssertTrue(texts.allSatisfy { $0.contains("Av. Catalunya") })

        // A GPX keeps the original's text.
        XCTAssertEqual(NavDirector(points: lRoute(), title: "Office").turnTexts, [:])
    }

    func testShortInstructionKeepsTheStreet() {
        XCTAssertEqual(NavDirector.shortInstruction("Turn right onto Carrer Major"), "Carrer Major")
        XCTAssertEqual(NavDirector.shortInstruction("Gira a la derecha hacia Av. Catalunya"), "Av. Catalunya")
        XCTAssertEqual(NavDirector.shortInstruction("Gira a la izquierda en Calle de Alcalá."), "Calle de Alcalá")
        XCTAssertEqual(NavDirector.shortInstruction("Turn left"), "Turn left")
        XCTAssertEqual(NavDirector.shortInstruction("Gira a la derecha"), "Gira a la derecha")
    }

    /// "Start at the nearest step": joining the second stretch skips the pointer back to the start.
    func testStartAtNearestStep() {
        func ride(nearest: Bool) -> (labels: [String], arrived: Bool) {
            var director = NavDirector(points: lRoute(), title: "Office")
            director.startAtNearestStep = nearest
            _ = director.start(ringConnected: true)
            var labels: [String] = []
            for i in 0...40 {
                let r = director.update(point(north: 200, east: 30 + Double(i) * 5))
                labels += r.commands.map(\.label)
                if r.arrived { return (labels, true) }
            }
            return (labels, false)
        }
        let nearest = ride(nearest: true)
        XCTAssertTrue(nearest.arrived)
        XCTAssertFalse(nearest.labels.contains("navPointer"))
        // From the start: off the route, so the ring first waits for a direction to point back.
        XCTAssertEqual(ride(nearest: false).labels.first, "navPointerStandby")
    }

    /// Matched engine: while the matcher waits to rejoin, the guidance doesn't compute the pointer.
    /// The direction of travel appearing on one of those fixes must not send the 999 placeholder as
    /// an angle: the ring keeps "ride to calibrate" until there is one.
    func testRejoiningKeepsRideToCalibrateUntilThePointerHasAnAngle() {
        var director = NavDirector(points: lRoute(), title: "Office")
        director.enableMatching(stepAlong: [0, 200, 400])
        let match = NavMatch(status: .rejoining, target: point(north: 0, east: 0), along: 0, distance: 30,
                             confident: false, unambiguous: true)
        var labels: [String] = []
        for i in 0...8 {
            labels += director.update(point(north: 0, east: -40 + Double(i) * 5), match: match).commands.map(\.label)
        }
        XCTAssertNotEqual(director.guidance?.bearing.crowFlies, NavBearing.unknown)
        XCTAssertFalse(labels.isEmpty)
        XCTAssertTrue(labels.allSatisfy { $0 == "navPointerStandby" })
    }

    // MARK: - As the crow flies

    func testCompassPointsAtTheDestinationAndArrives() {
        var compass = CompassDirector(destination: point(north: 300, east: 0), title: "Area 51")
        XCTAssertEqual(compass.start(ringConnected: true).map(\.label), ["turnByTurnIntro", "carouselPosition"])
        var labels: [String] = []
        var angles: [Int] = []
        var arrived = false
        for i in 0...60 {
            let r = compass.update(point(north: Double(i) * 5, east: 0))
            labels += r.commands.map(\.label)
            angles += r.commands.filter { $0.label == "navPointer" }.map {
                let b = [UInt8]($0.data)
                return Int(Int16(bitPattern: UInt16(b[5]) << 8 | UInt16(b[6])))
            }
            if r.arrived { arrived = true; break }
        }
        XCTAssertEqual(labels.first, "navPointerStandby")          // direction unknown yet
        XCTAssertFalse(angles.isEmpty)
        XCTAssertTrue(angles.allSatisfy { abs($0) <= 5 })          // dead ahead
        XCTAssertTrue(arrived)
        XCTAssertEqual(labels.suffix(4), ["navPointerOff", "sound", "nav", "navOff"])
    }

    /// Before the GPS knows the direction, a phone heading stands in: facing east, a destination to
    /// the north is 90° to the left.
    func testCompassUsesThePhoneHeadingUntilTheGPSHasOne() {
        var compass = CompassDirector(destination: point(north: 1000, east: 0), title: "Area 51")
        let r = compass.update(point(north: 0, east: 0), heading: 90)
        XCTAssertEqual(r.commands.map(\.label), ["navPointer"])
        let b = [UInt8](r.commands[0].data)
        XCTAssertEqual(Int(Int16(bitPattern: UInt16(b[5]) << 8 | UInt16(b[6]))), -90)
    }
}
