import Foundation

/// Plays a recorded ride (`RideTrace`) back through the ride logic (docs/MAP_MATCHING_SPEC.md §12.3):
/// the same fixes and rider actions into a fresh `RideEngine`, with the recorded engine or another one,
/// to check a change against rides from the road or to compare the classic and matched engines.
///
/// Only the fixes and events are replayed: the ring's carousel reports and the phone's compass aren't
/// recorded, so a ride that used them can differ in those commands.
public enum RideReplay {
    public struct Summary: Equatable, Sendable {
        public var fixes = 0
        /// Times the screen went off route / showed the wrong-way warning.
        public var offRouteEpisodes = 0
        public var wrongWayEpisodes = 0
        /// Index (among the fixes) of the fix that arrived.
        public var arrivedAt: Int?
        /// The ring commands of each fix.
        public var commands: [[RideTrace.Command]] = []
    }

    public enum ReplayError: Error { case noHeader }

    /// The ride a trace's header describes, on `engine` (or the one it was recorded with).
    public static func engine(from h: RideTrace.Header, engine: RideEngine.Engine? = nil) -> RideEngine {
        let points = h.points.compactMap { $0.count >= 2 ? GeoPoint($0[0], $0[1]) : nil }
        let nav = h.navPoints.compactMap { $0.count >= 2 ? GeoPoint($0[0], $0[1]) : nil }
        let settings = NavDirector.Settings(metric: h.metric, soundOn: h.soundOn, volume: h.volume, carouselCards: h.cards)
        if h.compass, let destination = points.last {
            return RideEngine(compassTo: destination, from: points.first, title: h.title, settings: settings)
        }
        let kind = engine ?? (h.engine == RideEngine.Engine.matched.rawValue ? .matched : .classic)
        return RideEngine(route: RouteGeometry(points: points, navPoints: nav), title: h.title, settings: settings,
                          instructions: h.instructions.map { (NavLocation($0.lat, $0.lon), $0.text) },
                          routedSteps: h.routedSteps ?? [], leadInLength: h.leadInLength,
                          joinNearest: h.joinNearest, engine: kind)
    }

    /// Replay the lines of a trace file (a header, then entries).
    public static func run(_ lines: [Data], engine kind: RideEngine.Engine? = nil) throws -> Summary {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf",
                                                                        negativeInfinity: "-inf", nan: "nan")
        guard let first = lines.first, let header = try? decoder.decode(RideTrace.Header.self, from: first) else {
            throw ReplayError.noHeader
        }
        var e = engine(from: header, engine: kind)
        var summary = Summary()
        var offRoute = false, wrongWay = false
        for line in lines.dropFirst() where !line.isEmpty {
            let entry = try decoder.decode(RideTrace.Entry.self, from: line)
            switch entry.event {
            case "invert": if let inverted = e.inverted() { e = inverted.engine }
            case "ignoreWrongWay": e.ignoreWrongWay()
            default: break
            }
            guard let fix = entry.fix else { continue }
            let r = e.update(fix)
            summary.commands.append(r.commands.map(RideTrace.Command.init))
            if e.snapshot.offRoute && !offRoute { summary.offRouteEpisodes += 1 }
            if e.snapshot.wrongWay == true && !wrongWay { summary.wrongWayEpisodes += 1 }
            offRoute = e.snapshot.offRoute
            wrongWay = e.snapshot.wrongWay == true
            if r.arrived && summary.arrivedAt == nil { summary.arrivedAt = summary.fixes }
            summary.fixes += 1
            if r.arrived { break }
        }
        return summary
    }
}
