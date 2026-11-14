import Foundation

/// BRouter's HTTP API (docs/APP_SPEC.md M17): the request's URL. The base URL is the rider's, from
/// Settings: BRouter itself (`http://localhost:17777`) or a proxy in front of it
/// (`https://brouter.example.org/routing`), whose own path is kept; the request goes to
/// `<base>/brouter?lonlats=lon,lat|lon,lat&profile=…&alternativeidx=…&format=geojson&timode=…`.
public enum BRouterRequest {
    /// The path under the base URL.
    public static let path = "brouter"
    /// Turn-instruction mode: BRouter only writes voice hints with one, and this one tells "exit
    /// left / right" (17, 18) apart from "keep left / right" (8, 9).
    public static let turnInstructionMode = 2
    /// Decimals of a coordinate in the request (about 10 cm).
    static let coordinateDecimals = 6

    /// The GET URL for a route through `points` (two or more; the ones in between are stops) on
    /// `profile` (a `.brf` name without the extension), the `alternative`th alternative (0 = the
    /// best). Nil with fewer than two points or a base URL without a host.
    public static func url(base: URL, points: [GeoPoint], profile: String, alternative: Int = 0) -> URL? {
        guard points.count >= 2, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
              parts.host != nil else { return nil }
        var basePath = parts.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        parts.path = basePath + "/" + path
        parts.queryItems = [
            URLQueryItem(name: "lonlats", value: points.map { coordinate($0.lon) + "," + coordinate($0.lat) }
                .joined(separator: "|")),
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "alternativeidx", value: String(alternative)),
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "timode", value: String(turnInstructionMode)),
        ]
        return parts.url
    }

    static func coordinate(_ degrees: Double) -> String {
        String(format: "%.\(coordinateDecimals)f", degrees)
    }
}

/// What BRouter answers with `format=geojson`: one `LineString` feature whose coordinates carry the
/// elevation and whose properties hold the length, the time and the voice hints, read into a route
/// with typed steps for the ring. Foundation only, so the app's client stays a thin `URLSession`
/// call and this is tested on Linux.
public struct BRouterRoute: Equatable, Sendable {
    public var points: [GeoPoint]
    /// Elevation per point (BRouter leaves it out where it has none).
    public var elevations: [Double?]
    /// The route cut at the voice hints, each step with the manoeuvre at its start.
    public var steps: [RoutedStep]
    /// `track-length`, metres.
    public var length: Double
    /// `total-time`, seconds; nil when the profile gives none.
    public var duration: Double?
    /// `filtered ascend`, metres of climb; nil when absent.
    public var ascent: Double?

    public enum ParseError: Error, Equatable, LocalizedError {
        /// Not the GeoJSON BRouter writes for a route: the body's text (BRouter answers "no route
        /// found" and its other errors as plain text).
        case notARoute(String)
        case tooFewPoints

        public var errorDescription: String? {
            switch self {
            case .notARoute(let text): text.isEmpty ? "BRouter sent no route." : "BRouter: \(text)"
            case .tooFewPoints: "BRouter sent a route with fewer than two points."
            }
        }
    }

    /// BRouter's command codes in the GeoJSON (`Formatter.getJsonCommandIndex`): 1 C, 2 TL, 3 TSLL,
    /// 4 TSHL, 5 TR, 6 TSLR, 7 TSHR, 8 KL, 9 KR, 10 TLU, 11 TRU, 12 OFFR, 13 RNDB, 14 RNLB, 15 TU,
    /// 16 BL, 17 EL, 18 ER.
    public enum Command: Int, Sendable {
        case straight = 1, left, slightLeft, sharpLeft, right, slightRight, sharpRight
        case keepLeft, keepRight, uTurnLeft, uTurnRight, offRoute, roundabout, roundaboutLeft, uTurn
        case beeline, exitLeft, exitRight
    }

    /// One voice hint: `[indexInTrack, command, exitNumber, distanceToNext, angle]` (a sixth element,
    /// the geometry string, in modes 4 and 9).
    public struct VoiceHint: Equatable, Sendable {
        /// Index of the manoeuvre's node in the track's coordinates.
        public var index: Int
        public var command: Int
        /// The roundabout's exit, signed (negative: left-hand traffic); 0 elsewhere.
        public var exit: Int
        /// Metres to the next hint.
        public var distanceToNext: Double
        /// Degrees, negative = left.
        public var angle: Double

        public init(index: Int, command: Int, exit: Int, distanceToNext: Double, angle: Double) {
            self.index = index; self.command = command; self.exit = exit
            self.distanceToNext = distanceToNext; self.angle = angle
        }

        init?(_ raw: [Any]) {
            guard raw.count >= 5, let index = BRouterRoute.number(raw[0]), let command = BRouterRoute.number(raw[1]),
                  let exit = BRouterRoute.number(raw[2]), let distance = BRouterRoute.number(raw[3]),
                  let angle = BRouterRoute.number(raw[4]) else { return nil }
            self.init(index: Int(index), command: Int(command), exit: Int(exit), distanceToNext: distance, angle: angle)
        }

        public var maneuver: RoutedManeuver? { BRouterRoute.maneuver(command: command, exit: exit) }
    }

    /// The typed manoeuvre of a command; nil for the hints that aren't one (off route, beeline).
    public static func maneuver(command: Int, exit: Int) -> RoutedManeuver? {
        guard let c = Command(rawValue: command) else { return nil }
        switch c {
        case .straight: return .straight
        case .left: return .left
        case .slightLeft: return .slightLeft
        case .sharpLeft: return .sharpLeft
        case .right: return .right
        case .slightRight: return .slightRight
        case .sharpRight: return .sharpRight
        case .keepLeft, .exitLeft: return .keepLeft
        case .keepRight, .exitRight: return .keepRight
        case .uTurnLeft, .uTurnRight, .uTurn: return .uTurn
        case .roundabout: return .roundabout(exit: max(1, abs(exit)), clockwise: false)
        case .roundaboutLeft: return .roundabout(exit: max(1, abs(exit)), clockwise: true)
        case .offRoute, .beeline: return nil
        }
    }

    public static func parse(_ data: Data) throws -> BRouterRoute {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]],
              let track = features.first(where: { ($0["geometry"] as? [String: Any])?["type"] as? String == "LineString" }),
              let geometry = track["geometry"] as? [String: Any],
              let coordinates = geometry["coordinates"] as? [[Any]] else {
            let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ParseError.notARoute(text)
        }
        var points: [GeoPoint] = []
        var elevations: [Double?] = []
        for c in coordinates {
            guard c.count >= 2, let lon = number(c[0]), let lat = number(c[1]) else { continue }
            points.append(GeoPoint(lat, lon))
            elevations.append(c.count >= 3 ? number(c[2]) : nil)
        }
        guard points.count >= 2 else { throw ParseError.tooFewPoints }
        let properties = track["properties"] as? [String: Any] ?? [:]
        let hints = ((properties["voicehints"] as? [[Any]]) ?? []).compactMap(VoiceHint.init)
        return BRouterRoute(points: points, elevations: elevations,
                            steps: steps(points: points, hints: hints),
                            length: number(properties["track-length"]) ?? RouteGeometry(points: points).length,
                            duration: number(properties["total-time"]).flatMap { $0 > 0 ? $0 : nil },
                            ascent: number(properties["filtered ascend"]))
    }

    /// The route cut at the hints: each step runs from one manoeuvre to the next and carries the
    /// manoeuvre at its start, with a zero-length "arrive" step last, so `RoutedStep.stretches` reads
    /// the manoeuvres at the start of each stretch. Hints that aren't manoeuvres are skipped.
    static func steps(points: [GeoPoint], hints: [VoiceHint]) -> [RoutedStep] {
        var steps: [RoutedStep] = []
        var start = 0
        var maneuver: RoutedManeuver? = .depart
        for hint in hints.sorted(by: { $0.index < $1.index }) {
            guard let m = hint.maneuver else { continue }
            let i = min(max(hint.index, 0), points.count - 1)
            if i > start {
                steps.append(RoutedStep(points: Array(points[start...i]), text: "", maneuver: maneuver))
                start = i
            }
            maneuver = m
        }
        if start < points.count - 1 {
            steps.append(RoutedStep(points: Array(points[start...]), text: "", maneuver: maneuver))
        }
        let end = points[points.count - 1]
        steps.append(RoutedStep(points: [end, end], text: "", maneuver: .arrive))
        return steps
    }

    /// BRouter quotes most numbers ("track-length": "12345"); JSON numbers come as such.
    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
