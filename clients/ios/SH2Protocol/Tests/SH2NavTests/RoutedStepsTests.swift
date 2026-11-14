import XCTest
@testable import SH2Nav

/// A routed destination on its own steps (`RoutedStep`) instead of the GPX turn detector.
final class RoutedStepsTests: XCTestCase {

    let lat0 = 41.39, lon0 = 2.16
    func point(north: Double, east: Double) -> GeoPoint {
        GeoPoint(lat0 + north / 111_195, lon0 + east / (111_195 * cos(lat0 * .pi / 180)))
    }

    /// Straight from one point to another, a point every 10 m.
    func line(_ a: (north: Double, east: Double), _ b: (north: Double, east: Double)) -> [GeoPoint] {
        let n = max(1, Int((hypot(b.north - a.north, b.east - a.east) / 10).rounded()))
        return (0...n).map {
            let t = Double($0) / Double(n)
            return point(north: a.north + (b.north - a.north) * t, east: a.east + (b.east - a.east) * t)
        }
    }

    /// `stretches` with a text for each manoeuvre between them (`texts.count == stretches.count - 1`),
    /// laid out the way Apple would if its instructions belong to the end of each polyline: a first
    /// step with no length, and the last one is the ride to "Arrive".
    func stepsAtEnd(_ stretches: [[GeoPoint]], _ texts: [String]) -> [RoutedStep] {
        let start = stretches[0][0]
        return [RoutedStep(points: [start, start], text: "Start on Avinguda Diagonal")]
            + stretches.indices.map {
                RoutedStep(points: stretches[$0], text: $0 < texts.count ? texts[$0] : "Arrive at the destination")
            }
    }

    /// The same, if they belong to the start of each polyline: the last step, "Arrive", has no length.
    func stepsAtStart(_ stretches: [[GeoPoint]], _ texts: [String]) -> [RoutedStep] {
        let end = stretches[stretches.count - 1].last!
        return stretches.indices.map {
            RoutedStep(points: stretches[$0], text: $0 == 0 ? "Head north on Avinguda Diagonal" : texts[$0 - 1])
        } + [RoutedStep(points: [end, end], text: "Arrive at the destination")]
    }

    /// 300 m north, then 300 m east.
    var corner: [[GeoPoint]] { [line((0, 0), (300, 0)), line((300, 0), (300, 300))] }

    func rideAlong(_ stretches: [[GeoPoint]]) -> [GeoPoint] {
        stretches.flatMap { $0 }
    }

    func engine(_ steps: [RoutedStep], _ stretches: [[GeoPoint]]) -> RideEngine {
        RideEngine(route: RouteGeometry(points: rideAlong(stretches)), title: "Test", settings: .init(),
                   routedSteps: steps)
    }

    /// Every `navAngle` of a ride along `points` at 5 m/s, one fix each 5 m.
    func navAngles(_ director: inout NavDirector, along points: [GeoPoint]) -> [Data] {
        _ = director.start(ringConnected: true)
        var out: [Data] = []
        let route = RouteGeometry(points: points)
        var along = 0.0
        while along <= route.length {
            let p = route.coordinate(at: along)
            out += director.update(NavLocation(p.lat, p.lon, accuracy: 5)).commands
                .filter { $0.label == "navAngle" }.map(\.data)
            along += 5
        }
        return out
    }

    // MARK: - Finding the turns

    func testACornerIsATurn() {
        let (steps, texts) = NavStepFactory.steps(routed: stepsAtEnd(corner, ["Turn right onto Carrer Major"]))
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[1].angles, [90])
        XCTAssertEqual(steps[1].instruction, "nav.found.right")
        XCTAssertEqual(texts, [1: "Carrer Major"])
        XCTAssertEqual(steps.last?.type, NavStepType.destination)
    }

    /// The whole angle of a corner rounded over 24 m with points 4 m apart, where the GPX detector sees
    /// nothing.
    func testARoundedCornerIsATurn() {
        let r = 15.0
        let arc = (1..<6).map { i -> GeoPoint in
            let a = Double(i) / 6 * .pi / 2
            return point(north: 300 + r * sin(a), east: r - r * cos(a))
        }
        let before = line((0, 0), (300, 0)) + arc
        let after = line((315, 15), (315, 315))
        XCTAssertEqual(NavStepFactory.steps(from: (before + after).map { NavLocation($0.lat, $0.lon) }).count, 2)

        let steps = NavStepFactory.steps(routed: stepsAtEnd([before, after], ["Turn right"])).steps
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(Double(steps[1].angles[0]), 90, accuracy: 15)
    }

    func testAGentleForkIsATurnAndSaysSo() {
        let east = 200 * sin(30.0 * .pi / 180), north = 200 * cos(30.0 * .pi / 180)
        let fork = [line((0, 0), (300, 0)), line((300, 0), (300 + north, east))]
        let steps = stepsAtEnd(fork, ["Keep right onto Carrer Major"])
        let built = NavStepFactory.steps(routed: steps).steps
        XCTAssertEqual(built.count, 3)
        XCTAssertEqual(Double(built[1].angles[0]), 30, accuracy: 2)
        XCTAssertEqual(built[1].instruction, "nav.found.right")      // not the detector's > 44

        var e = engine(steps, fork)
        _ = e.update(RideFix(lat: fork[0][0].lat, lon: fork[0][0].lon, speed: 5))
        XCTAssertEqual(e.snapshot.nextTurnText, "Carrer Major")
        XCTAssertEqual(e.snapshot.nextTurn, .slightRight)
    }

    func testANewStreetNameIsNotATurn() {
        let stretches = [line((0, 0), (300, 0)), line((300, 0), (600, 5)), line((600, 5), (600, 300))]
        let steps = stepsAtEnd(stretches, ["Continue onto Carrer Major", "Turn right onto Carrer Nou"])
        let (built, texts) = NavStepFactory.steps(routed: steps)
        XCTAssertEqual(built.count, 3)
        XCTAssertEqual(texts, [1: "Carrer Nou"])
        XCTAssertEqual(built[0].path.count, stretches[0].count + stretches[1].count - 1)
    }

    func testEachStepKnowsItsLength() {
        let built = NavStepFactory.steps(routed: stepsAtEnd(corner, ["Turn right"])).steps
        XCTAssertEqual(built[0].firstDistance, 300, accuracy: 3)
        XCTAssertEqual(built[1].firstDistance, 300, accuracy: 3)
    }

    /// Without a real length every turn would look like a quick one, and its arc would stay on.
    func testTheArcGoesAwayAfterTheTurn() {
        let steps = stepsAtEnd(corner, ["Turn right onto Carrer Major"])
        var director = NavDirector(routed: steps, title: "Office")
        _ = director.start(ringConnected: true)
        var removed = false
        let route = RouteGeometry(points: rideAlong(corner))
        var along = 0.0
        while along <= 420 {
            let p = route.coordinate(at: along)
            let r = director.update(NavLocation(p.lat, p.lon, accuracy: 5))
            if along > 300 { removed = removed || r.commands.contains { $0.label == "navOff" } }
            along += 5
        }
        XCTAssertTrue(removed)
        XCTAssertEqual(director.guidance?.currentStepIndex, 1)
        XCTAssertEqual(director.guidance?.display.isStepAnimationNow, false)
    }

    // MARK: - Which instruction goes with which turn

    func testBothEndsOfThePolylineGiveTheSameTexts() {
        let stretches = [line((0, 0), (300, 0)), line((300, 0), (300, 300)), line((300, 300), (600, 300))]
        let texts = ["Turn right onto Carrer Major", "Turn left onto Carrer Nou"]
        let end = NavStepFactory.steps(routed: stepsAtEnd(stretches, texts))
        let start = NavStepFactory.steps(routed: stepsAtStart(stretches, texts))
        XCTAssertEqual(end.texts, [1: "Carrer Major", 2: "Carrer Nou"])
        XCTAssertEqual(start.texts, end.texts)
        XCTAssertEqual(start.steps.map(\.angles), end.steps.map(\.angles))
        XCTAssertEqual(start.steps.map(\.entrance), end.steps.map(\.entrance))
    }

    /// The instructions of a route still on the detector go where the manoeuvres are.
    func testInstructionsAreAtTheManoeuvres() {
        let corner = point(north: 300, east: 0)
        for steps in [stepsAtEnd(self.corner, ["Turn right onto Carrer Major"]),
                      stepsAtStart(self.corner, ["Turn right onto Carrer Major"])] {
            let list = RoutedStep.instructions(steps)
            XCTAssertEqual(list.count, 1)
            XCTAssertEqual(list[0].text, "Carrer Major")
            XCTAssertLessThan(list[0].location.distance(to: NavLocation(corner.lat, corner.lon)), 1)
        }
    }

    // MARK: - Caution

    func testACautionStepUsesTheCautionColour() {
        var steps = stepsAtEnd(corner, ["Turn right onto Carrer Major"])
        steps[2].caution = true
        var director = NavDirector(routed: steps, title: "Office")
        XCTAssertEqual(director.steps[1].mode, 1)
        let caution = Data([38, 234, 249])
        let arcs = navAngles(&director, along: rideAlong(corner))
        XCTAssertFalse(arcs.isEmpty)
        XCTAssertTrue(arcs.contains { $0.range(of: caution) != nil })
    }

    func testAChangeToCautionIsKeptEvenStraightOn() {
        var steps = stepsAtEnd([line((0, 0), (300, 0)), line((300, 0), (600, 0))], ["Continue onto the path"])
        steps[2].caution = true
        let built = NavStepFactory.steps(routed: steps).steps
        XCTAssertEqual(built.count, 3)
        XCTAssertEqual(built[1].mode, 1)
    }

    // MARK: - Roundabouts

    /// A roundabout from the south, leaving east after going round it: the entrance bends the other way.
    func testARoundaboutAimsAtItsWayOut() {
        let around = [point(north: 300, east: 0), point(north: 312, east: 10), point(north: 318, east: 22),
                      point(north: 312, east: 34)]
        let out = line((312, 34), (312, 400))
        let stretches = [line((0, 0), (300, 0)), around + out.dropFirst()]
        let (built, texts) = NavStepFactory.steps(routed: stepsAtEnd(
            stretches, ["At the roundabout, take the first exit onto Carrer Major"]))
        XCTAssertEqual(Double(built[1].angles[0]), 90, accuracy: 5)
        XCTAssertEqual(texts, [1: "Exit 1 · Carrer Major"])
    }

    /// Straight on is ≈ 0°, and it's still a manoeuvre: the rider has to take the right exit.
    func testGoingStraightThroughARoundaboutIsKept() {
        let around = [point(north: 300, east: 0), point(north: 310, east: 12), point(north: 325, east: 12),
                      point(north: 335, east: 0)]
        let stretches = [line((0, 0), (300, 0)), around + line((335, 0), (635, 0)).dropFirst()]
        let steps = stepsAtEnd(stretches, ["En la rotonda, toma la segunda salida hacia Carrer Major"])
        let (built, texts) = NavStepFactory.steps(routed: steps)
        XCTAssertEqual(built.count, 3)
        XCTAssertEqual(texts, [1: "Salida 2 · Carrer Major"])

        // With the exit read from the text, the ring gets its own roundabout glyph and the screen the exit.
        XCTAssertEqual(built[1].type, NavStepType.roundaboutCounterClockwise)
        XCTAssertEqual(built[1].maneuver, .roundabout(exit: 2, clockwise: false))
        var e = engine(steps, stretches)
        _ = e.update(RideFix(lat: stretches[0][0].lat, lon: stretches[0][0].lon, speed: 5))
        XCTAssertEqual(e.snapshot.nextTurn, .roundabout)
        XCTAssertEqual(e.snapshot.nextTurnExit, 2)
    }

    /// However big it is: going round takes 80 m here and 280 m there, for the same way out.
    func testTheWayOutDoesNotDependOnTheRoundaboutsSize() {
        for r in [12.0, 45.0] {
            // In from the south, anticlockwise past the east and north sides, out to the west.
            let centre = (north: 300 + r, east: 0.0)
            let arc = (0...24).map { i -> GeoPoint in
                let a = -Double.pi / 2 + Double(i) / 24 * 1.5 * .pi
                return point(north: centre.north + r * sin(a), east: centre.east + r * cos(a))
            }
            let out = line((centre.north, -r), (centre.north, -300))
            let stretches = [line((0, 0), (300, 0)), arc + out.dropFirst()]
            let built = NavStepFactory.steps(routed: stepsAtEnd(
                stretches, ["At the roundabout, take the third exit"])).steps
            XCTAssertEqual(Double(built[1].angles[0]), -90, accuracy: 15, "radius \(r)")
        }
    }

    /// The exits for the ring's glyph: the one to take first, then the ones passed on the way to it,
    /// spread between the entry and the exit (counter-clockwise in right-hand traffic).
    func testRoundaboutExitAngles() {
        XCTAssertEqual(RoundaboutExits.angles(exit: 1, angle: 90, clockwise: false), [90])
        XCTAssertEqual(RoundaboutExits.angles(exit: 2, angle: 0, clockwise: false), [0, 90])
        XCTAssertEqual(RoundaboutExits.angles(exit: 3, angle: -90, clockwise: false), [-90, 90, 0])
        XCTAssertEqual(RoundaboutExits.angles(exit: 2, angle: 0, clockwise: true), [0, -90])
        XCTAssertEqual(RoundaboutExits.angles(exit: 12, angle: 0, clockwise: false).count, RoundaboutExits.maximumExits)
    }

    /// A typed roundabout (BRouter) needs no text: a ROUNDABOUT step with its exits, and the ring gets
    /// its own roundabout commands as the rider nears it, blinking once inside.
    func testATypedRoundaboutDrivesTheRingsRoundabout() {
        let around = [point(north: 300, east: 0), point(north: 310, east: 12), point(north: 325, east: 12),
                      point(north: 335, east: 0)]
        let stretches = [line((0, 0), (300, 0)), around + line((335, 0), (635, 0)).dropFirst()]
        let steps = [RoutedStep(points: stretches[0], text: "", maneuver: .depart),
                     RoutedStep(points: stretches[1], text: "", maneuver: .roundabout(exit: 2, clockwise: false)),
                     RoutedStep(points: [stretches[1].last!, stretches[1].last!], text: "", maneuver: .arrive)]
        let (built, texts) = NavStepFactory.steps(routed: steps)
        XCTAssertEqual(built.count, 3)
        XCTAssertEqual(built[1].type, NavStepType.roundaboutCounterClockwise)
        XCTAssertTrue(built[1].isRoundabout)
        XCTAssertEqual(built[1].angles.count, 2)
        XCTAssertEqual(Double(built[1].angles[0]), 0, accuracy: 20)          // straight through
        XCTAssertGreaterThan(built[1].roundaboutExitDistance, 20)
        XCTAssertLessThan(built[1].exit.distance(to: NavLocation(around[3].lat, around[3].lon)), 60)
        XCTAssertEqual(texts, [1: "Exit 2"])

        var director = NavDirector(routed: steps, title: "Office")
        _ = director.start(ringConnected: true)
        var labels: [String] = []
        var blinking = false
        let route = RouteGeometry(points: rideAlong(stretches))
        var along = 0.0
        while along <= 330 {
            let p = route.coordinate(at: along)
            let r = director.update(NavLocation(p.lat, p.lon, accuracy: 5), speed: 5)
            labels += r.commands.map(\.label)
            for c in r.commands where c.label == "roundabout" {
                let bytes = [UInt8](c.data)
                XCTAssertEqual(bytes[3], Commands.RoundaboutStyle.counterClockwise.rawValue)
                XCTAssertEqual(bytes.count, 10 + 2 * 2)                        // two exits
                if bytes[2] == 1 { blinking = true }
            }
            along += 5
        }
        XCTAssertTrue(labels.contains("roundabout"))
        XCTAssertTrue(labels.contains("roundaboutOled"))
        XCTAssertFalse(labels.contains("navAngle"))
        XCTAssertTrue(blinking)

        var e = engine(steps, stretches)
        _ = e.update(RideFix(lat: stretches[0][0].lat, lon: stretches[0][0].lon, speed: 5))
        XCTAssertEqual(e.snapshot.nextTurn, .roundabout)
        XCTAssertEqual(e.snapshot.nextTurnExit, 2)
        XCTAssertEqual(e.snapshot.nextTurnText, "Exit 2")
    }

    /// A typed "keep right" at a shallow fork is a turn, where a text-only step of 12° would merge.
    func testATypedKeepRightIsKeptHoweverShallow() {
        let east = 200 * sin(12.0 * .pi / 180), north = 200 * cos(12.0 * .pi / 180)
        let fork = [line((0, 0), (300, 0)), line((300, 0), (300 + north, east))]
        let typed = [RoutedStep(points: fork[0], text: "", maneuver: .depart),
                     RoutedStep(points: fork[1], text: "", maneuver: .keepRight),
                     RoutedStep(points: [fork[1].last!, fork[1].last!], text: "", maneuver: .arrive)]
        XCTAssertEqual(NavStepFactory.steps(routed: typed).steps.count, 3)
        XCTAssertEqual(NavStepFactory.steps(routed: stepsAtEnd(fork, ["Continue"])).steps.count, 2)
        var e = engine(typed, fork)
        _ = e.update(RideFix(lat: fork[0][0].lat, lon: fork[0][0].lon, speed: 5))
        XCTAssertEqual(e.snapshot.nextTurn, .slightRight)
    }

    func testRoundaboutTexts() {
        XCTAssertEqual(RoutedStep.oledText("Toma la 2.ª salida en la rotonda"), "Salida 2")
        XCTAssertEqual(RoutedStep.oledText("At the roundabout, take the 3rd exit"), "Exit 3")
        XCTAssertEqual(RoutedStep.oledText("En la glorieta, toma la tercera salida hacia Calle Primera"),
                       "Salida 3 · Calle Primera")
        XCTAssertEqual(RoutedStep.oledText("Enter the roundabout onto Carrer Major"), "Carrer Major")
        XCTAssertEqual(RoutedStep.oledText("Turn left onto Carrer Major"), "Carrer Major")
    }

    // MARK: - The engine

    func testTheScreenFollowsTheSteps() {
        let route = RouteGeometry(points: rideAlong(corner))
        var e = engine(stepsAtEnd(corner, ["Turn right onto Carrer Major"]), corner)
        XCTAssertEqual(e.director?.routed, true)
        var along = 0.0, t = 0.0
        while along <= 250 {
            let p = route.coordinate(at: along)
            _ = e.update(RideFix(lat: p.lat, lon: p.lon, speed: 5, time: t))
            along += 5; t += 1
        }
        XCTAssertEqual(e.snapshot.nextTurnText, "Carrer Major")
        XCTAssertEqual(e.snapshot.nextTurn, .right)
    }

    /// Steps that don't add up to the route can't be trusted: the detector takes over.
    func testStepsThatDontAddUpFallBackToTheDetector() {
        let steps = stepsAtEnd([corner[0]], [])
        let route = RouteGeometry(points: rideAlong(corner))
        XCTAssertFalse(RoutedStep.covers(steps, length: route.length))
        let e = RideEngine(route: route, title: "Test", settings: .init(), routedSteps: steps)
        XCTAssertEqual(e.director?.routed, false)
        XCTAssertEqual(e.director?.steps.count, 3)
    }

    func testAGPXRideIsNotRouted() {
        let e = RideEngine(route: RouteGeometry(points: rideAlong(corner)), title: "Test", settings: .init())
        XCTAssertEqual(e.director?.routed, false)
    }

    /// A track recorded by a phone: the detector splits it where the points around give under 30°. A
    /// GPX keeps the original's banner there, not a routed ride's slight turn.
    func testASmallAngleOnAGPXKeepsItsBanner() throws {
        let track: [(Double, Double)] = [
            (0.0, 0.0), (3.0, -0.3), (5.7, -0.4), (8.1, 0.1), (11.2, 0.8), (12.9, 0.8), (14.8, 0.2), (17.0, 0.3),
            (18.3, 0.1), (21.1, -0.1), (24.0, 0.5), (26.7, 0.3), (31.0, -0.3), (33.0, -1.2), (35.2, -0.8),
            (37.5, -1.6), (39.8, -1.2), (41.9, 0.4), (44.8, -1.1), (47.7, -1.1), (50.6, -0.9), (52.2, -0.9),
            (55.5, 0.0), (56.8, -1.1), (60.3, -0.8), (61.3, -0.2), (64.0, 0.2), (66.9, -0.8), (69.1, -1.2),
            (71.2, -0.5), (73.4, -0.8), (75.3, -0.4), (76.5, -0.7), (80.6, -0.6), (83.5, -0.8), (85.7, -1.5),
            (88.2, -1.5), (90.8, -2.0), (92.7, -2.8), (97.0, -3.8), (99.1, -3.7), (102.3, -3.6), (104.6, -4.3),
            (107.0, -5.5), (109.7, -5.0), (112.2, -4.0), (113.2, -4.7), (115.4, -4.4), (117.8, -4.5),
            (120.9, -4.0), (123.9, -3.3), (125.9, -4.4), (128.4, -5.1), (130.9, -4.8), (133.3, -4.8),
            (135.7, -5.8), (137.0, -4.6), (140.0, -6.8), (142.2, -6.7), (144.3, -5.8),
        ]
        let route = RouteGeometry(points: track.map { point(north: $0.0, east: $0.1) })
        let e = RideEngine(route: route, title: "Test", settings: .init())
        let angle = try XCTUnwrap(e.director?.steps[1].angles.first)
        XCTAssertLessThan(abs(angle), 30)
        XCTAssertEqual(e.snapshot.nextTurn, angle > 0 ? .right : .left)
    }

    func testTheTraceKeepsTheStepsOfARoutedRideOnly() throws {
        var steps = stepsAtEnd(corner, ["Turn right onto Carrer Major"])
        steps[1].maneuver = .right
        let routed = engine(steps, corner)
        let header = RideTrace.Header(engine: routed, title: "Test", routedSteps: steps)
        let line = try XCTUnwrap(RideTrace.line(header))
        XCTAssertEqual(try JSONDecoder().decode(RideTrace.Header.self, from: line).routedSteps, steps)
        // A trace from before the manoeuvre types decodes with none.
        let old = Data("{\"points\":[{\"lat\":41.39,\"lon\":2.16}],\"text\":\"Turn right\",\"caution\":false}".utf8)
        XCTAssertNil(try JSONDecoder().decode(RoutedStep.self, from: old).maneuver)

        let gpx = RideEngine(route: RouteGeometry(points: rideAlong(corner)), title: "Test", settings: .init())
        let plain = try XCTUnwrap(RideTrace.line(RideTrace.Header(engine: gpx, title: "Test")))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("routedSteps"))
    }
}
