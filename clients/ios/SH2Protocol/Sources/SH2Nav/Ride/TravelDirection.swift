import Foundation

/// The rider's direction of travel from how far they have moved (docs/MAP_MATCHING_SPEC.md §4.3), not
/// from the bearing between two consecutive fixes, which at 1 Hz gives nothing under ~12.6 km/h
/// (`NavBearing`). Used by the route matcher and the wrong-way detector only: the ring's pointer keeps
/// `NavBearing`, as in the official app.
public struct TravelDirection: Sendable {
    public struct Estimate: Equatable, Sendable, Codable {
        /// Degrees 0…360, 0 = north.
        public var bearing: Double
        /// Metres the estimate spans (0 for the GPS course).
        public var length: Double

        public init(bearing: Double, length: Double) {
            self.bearing = bearing; self.length = length
        }
    }

    struct Sample: Sendable {
        var point: GeoPoint
        var accuracy: Double
        var time: Double
    }

    /// Fixes older than this are dropped.
    static let history = 60.0
    /// The displacement must reach max(`minimumBaseline`, `baselineFactor` × the two accuracies)…
    static let minimumBaseline = 15.0
    static let baselineFactor = 1.2
    /// …within this, or the fixes jumped.
    static let maximumBaseline = 150.0
    /// The unit vectors towards the newest fix must agree this much (1 = all the same way).
    static let coherence = 0.85

    private(set) var samples: [Sample] = []

    public init() {}

    mutating func add(_ point: GeoPoint, accuracy: Double, time: Double) {
        samples.append(Sample(point: point, accuracy: max(0, accuracy), time: time))
        if let first = samples.firstIndex(where: { time - $0.time <= Self.history }), first > 0 {
            samples.removeFirst(first)
        }
    }

    /// Walk back from the newest fix, adding the unit vector from each older fix towards it, until one
    /// is far enough away to beat the accuracy of both; the direction is the chord from that fix, if
    /// the walk went one way.
    public func estimate() -> Estimate? {
        guard let newest = samples.last, samples.count >= 2 else { return nil }
        var sx = 0.0, sy = 0.0, count = 0.0
        for s in samples.dropLast().reversed() {
            let (x, y) = Self.offset(from: s.point, to: newest.point)
            let d = (x * x + y * y).squareRoot()
            if d > 0 { sx += x / d; sy += y / d; count += 1 }
            let baseline = max(Self.minimumBaseline, Self.baselineFactor * (s.accuracy + newest.accuracy))
            guard d >= baseline else { continue }
            guard d <= Self.maximumBaseline, count > 0,
                  (sx * sx + sy * sy).squareRoot() / count >= Self.coherence else { return nil }
            return Estimate(bearing: Self.bearing(x, y), length: d)
        }
        return nil
    }

    /// The displacement over the last `metres` of path ridden (the chord from the fix where the path
    /// reaches that length to the newest one); nil until the rider has covered that much.
    public func vector(over metres: Double) -> Estimate? {
        guard let newest = samples.last else { return nil }
        var path = 0.0
        var previous = newest.point
        for s in samples.dropLast().reversed() {
            let (px, py) = Self.offset(from: s.point, to: previous)
            path += (px * px + py * py).squareRoot()
            previous = s.point
            guard path >= metres else { continue }
            let (x, y) = Self.offset(from: s.point, to: newest.point)
            return Estimate(bearing: Self.bearing(x, y), length: (x * x + y * y).squareRoot())
        }
        return nil
    }

    /// Metres east and north from `a` to `b`, on the same local plane as `RouteGeometry.match`.
    static func offset(from a: GeoPoint, to b: GeoPoint) -> (Double, Double) {
        ((b.lon - a.lon) * cos(a.lat * .pi / 180) * 111_320.0, (b.lat - a.lat) * 110_540.0)
    }

    static func bearing(_ east: Double, _ north: Double) -> Double {
        let deg = atan2(east, north) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}
