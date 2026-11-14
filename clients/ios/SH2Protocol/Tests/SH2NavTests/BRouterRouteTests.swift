import XCTest
@testable import SH2Nav

/// BRouter's request URL and GeoJSON answer (`BRouterRequest`, `BRouterRoute`).
final class BRouterRouteTests: XCTestCase {

    let madrid = GeoPoint(40.416775, -3.703790), retiro = GeoPoint(40.415, -3.6845)

    // MARK: - Request

    func testURLKeepsTheBasePathAndEncodesTheStops() throws {
        let direct = try XCTUnwrap(BRouterRequest.url(base: URL(string: "http://localhost:17777")!,
                                                      points: [madrid, retiro], profile: "trekking"))
        XCTAssertEqual(direct.absoluteString,
                       "http://localhost:17777/brouter?lonlats=-3.703790,40.416775%7C-3.684500,40.415000"
                       + "&profile=trekking&alternativeidx=0&format=geojson&timode=2")
        // Through a proxy with its own path, with or without a trailing slash: no double slash.
        for base in ["https://brouter.example.org/routing/brouter", "https://brouter.example.org/routing/brouter/"] {
            let url = try XCTUnwrap(BRouterRequest.url(base: URL(string: base)!, points: [madrid, retiro],
                                                       profile: "gravel", alternative: 2))
            XCTAssertTrue(url.absoluteString.hasPrefix("https://brouter.example.org/routing/brouter/brouter?"), base)
            XCTAssertFalse(url.absoluteString.contains("//brouter?"), base)
            XCTAssertTrue(url.absoluteString.contains("alternativeidx=2"))
        }
        // A stop in between is one more lon,lat.
        let via = try XCTUnwrap(BRouterRequest.url(base: URL(string: "https://brouter.example.org")!,
                                                   points: [madrid, GeoPoint(40.42, -3.69), retiro], profile: "mtb"))
        XCTAssertEqual(via.absoluteString.components(separatedBy: "%7C").count, 3)
        XCTAssertNil(BRouterRequest.url(base: URL(string: "https://brouter.example.org")!, points: [madrid], profile: "mtb"))
    }

    // MARK: - Response

    /// A straight 300 m north, a right turn, 300 m east through a roundabout's second exit, with BRouter's
    /// quoted numbers and a two-element coordinate where it has no elevation.
    let sample = """
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"creator":"BRouter-1.7.10",
    "name":"brouter_0","track-length":"600","filtered ascend":"12","plain-ascend":"-3","total-time":"150",
    "total-energy":"12345","cost":"900",
    "voicehints":[[3,5,0,300.0,88],[6,13,2,150.0,5],[8,1,0,30.0,2]],
    "messages":[["Longitude","Latitude","Elevation"]],"times":[0,20,40,60,80,100,120,140,160]},
    "geometry":{"type":"LineString","coordinates":[
    [-3.703790,40.416775,650],[-3.703790,40.417675,652],[-3.703790,40.418575,655],[-3.703790,40.419475],
    [-3.702610,40.419475,654],[-3.701430,40.419475,653],[-3.700250,40.419475,653],
    [-3.699070,40.419475,652],[-3.697890,40.419475,651],[-3.696710,40.419475,650]]}}]}
    """

    func testParsesTheTrackElevationAndTypedSteps() throws {
        let route = try BRouterRoute.parse(Data(sample.utf8))
        XCTAssertEqual(route.points.count, 10)
        XCTAssertEqual(route.points[0], GeoPoint(40.416775, -3.703790))
        XCTAssertEqual(route.elevations[0], 650)
        XCTAssertNil(route.elevations[3])
        XCTAssertEqual(route.length, 600)
        XCTAssertEqual(route.duration, 150)
        XCTAssertEqual(route.ascent, 12)
        // Steps: depart → index 3 (right), → 6 (roundabout exit 2), → 8 (continue), then "arrive".
        XCTAssertEqual(route.steps.map(\.maneuver), [.depart, .right, .roundabout(exit: 2, clockwise: false), .straight, .arrive])
        XCTAssertEqual(route.steps[0].points.count, 4)
        XCTAssertEqual(route.steps[1].points.first, route.points[3])
        XCTAssertEqual(route.steps[2].points.first, route.points[6])
        XCTAssertEqual(route.steps[3].points, Array(route.points[8...9]))
        XCTAssertEqual(route.steps.last?.length, 0)
        XCTAssertTrue(route.steps.allSatisfy { $0.text.isEmpty && !$0.caution })
        // They add up to the route, so the guidance takes them.
        let geometry = RouteGeometry(points: route.points, elevations: route.elevations)
        XCTAssertTrue(RoutedStep.covers(route.steps, length: geometry.length))
        XCTAssertEqual(geometry.totalGain, 5)
    }

    func testCommandCodesBecomeManeuvers() {
        XCTAssertEqual(BRouterRoute.maneuver(command: 1, exit: 0), .straight)
        XCTAssertEqual(BRouterRoute.maneuver(command: 2, exit: 0), .left)
        XCTAssertEqual(BRouterRoute.maneuver(command: 3, exit: 0), .slightLeft)
        XCTAssertEqual(BRouterRoute.maneuver(command: 4, exit: 0), .sharpLeft)
        XCTAssertEqual(BRouterRoute.maneuver(command: 5, exit: 0), .right)
        XCTAssertEqual(BRouterRoute.maneuver(command: 6, exit: 0), .slightRight)
        XCTAssertEqual(BRouterRoute.maneuver(command: 7, exit: 0), .sharpRight)
        XCTAssertEqual(BRouterRoute.maneuver(command: 8, exit: 0), .keepLeft)
        XCTAssertEqual(BRouterRoute.maneuver(command: 9, exit: 0), .keepRight)
        XCTAssertEqual(BRouterRoute.maneuver(command: 10, exit: 0), .uTurn)
        XCTAssertEqual(BRouterRoute.maneuver(command: 11, exit: 0), .uTurn)
        XCTAssertEqual(BRouterRoute.maneuver(command: 15, exit: 0), .uTurn)
        XCTAssertEqual(BRouterRoute.maneuver(command: 13, exit: 3), .roundabout(exit: 3, clockwise: false))
        XCTAssertEqual(BRouterRoute.maneuver(command: 14, exit: -2), .roundabout(exit: 2, clockwise: true))
        XCTAssertEqual(BRouterRoute.maneuver(command: 17, exit: 0), .keepLeft)
        XCTAssertEqual(BRouterRoute.maneuver(command: 18, exit: 0), .keepRight)
        XCTAssertNil(BRouterRoute.maneuver(command: 12, exit: 0))     // off route
        XCTAssertNil(BRouterRoute.maneuver(command: 16, exit: 0))     // beeline
        XCTAssertNil(BRouterRoute.maneuver(command: 99, exit: 0))
    }

    func testHintsThatAreNotManeuversDoNotCutTheRoute() throws {
        let hints = [BRouterRoute.VoiceHint(index: 2, command: 12, exit: 0, distanceToNext: 10, angle: 0),
                     BRouterRoute.VoiceHint(index: 4, command: 2, exit: 0, distanceToNext: 10, angle: -90)]
        let points = (0...6).map { GeoPoint(40 + Double($0) * 0.001, -3) }
        let steps = BRouterRoute.steps(points: points, hints: hints)
        XCTAssertEqual(steps.map(\.maneuver), [.depart, .left, .arrive])
        XCTAssertEqual(steps[0].points.count, 5)
    }

    func testAPlainTextErrorIsNotARoute() {
        XCTAssertThrowsError(try BRouterRoute.parse(Data("no route found\n".utf8))) { error in
            XCTAssertEqual(error as? BRouterRoute.ParseError, .notARoute("no route found"))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "BRouter: no route found")
        }
        let empty = """
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{},
        "geometry":{"type":"LineString","coordinates":[[-3.7,40.4]]}}]}
        """
        XCTAssertThrowsError(try BRouterRoute.parse(Data(empty.utf8))) { error in
            XCTAssertEqual(error as? BRouterRoute.ParseError, .tooFewPoints)
        }
    }
}
