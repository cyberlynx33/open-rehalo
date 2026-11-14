import Foundation

/// A latitude/longitude: the portable side of `CLLocationCoordinate2D`.
public struct GeoPoint: Equatable, Hashable, Sendable, Codable {
    public var lat: Double
    public var lon: Double

    public init(_ lat: Double, _ lon: Double) {
        self.lat = lat; self.lon = lon
    }

    /// Metres to `o`: the same haversine the ring guidance uses (`NavLocation.distance`).
    public func distance(to o: GeoPoint) -> Double {
        NavLocation(lat, lon).distance(to: NavLocation(o.lat, o.lon))
    }

    /// Initial bearing to `o` in degrees 0…359 (0 = north, 90 = east).
    public func bearing(to o: GeoPoint) -> Double {
        let lat1 = lat * .pi / 180, lat2 = o.lat * .pi / 180
        let dLon = (o.lon - lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Signed smallest difference `to - from` in degrees, in (-180, 180]. Positive = clockwise (right).
    public static func angleDelta(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

/// A route's shape: an ordered list of points (+ optional elevations), with the along-route geometry
/// precomputed for guidance (cumulative distance and climb per point).
public struct RouteGeometry: Equatable, Sendable {
    public let points: [GeoPoint]
    /// Elevation per point in metres (`nil` where the GPX has no `<ele>`). Same count as `points`.
    public let elevations: [Double?]
    /// Distance along the route at each point, metres. `cumulative[0] == 0`.
    public let cumulative: [Double]
    /// Smoothed climb accumulated up to each point, metres. Empty when the route has no elevation.
    public let cumulativeGain: [Double]
    /// The points the official app navigates (ring guidance, `NavDirector`): its `<trkpt>`s, or its
    /// `<wpt>`s when there are more of them; `<rte>` is ignored there. Falls back to `points` for a
    /// route-only GPX, which the official app couldn't navigate at all.
    public let navPoints: [GeoPoint]

    public init(points: [GeoPoint], elevations: [Double?] = [], navPoints: [GeoPoint]? = nil) {
        self.points = points
        self.navPoints = navPoints.flatMap { $0.isEmpty ? nil : $0 } ?? points
        let ele = elevations.count == points.count ? elevations : Array(repeating: nil, count: points.count)
        self.elevations = ele

        var cum = [Double](repeating: 0, count: points.count)
        for i in points.indices.dropFirst() {
            cum[i] = cum[i - 1] + points[i - 1].distance(to: points[i])
        }
        self.cumulative = cum

        // Climb with a 3 m hysteresis so GPS/DEM noise doesn't inflate the total.
        if ele.contains(where: { $0 != nil }) {
            var gains = [Double](repeating: 0, count: points.count)
            var ref: Double?
            var total = 0.0
            for i in points.indices {
                if let e = ele[i] {
                    if let r = ref {
                        if e - r >= 3 { total += e - r; ref = e } else if r - e >= 3 { ref = e }
                    } else {
                        ref = e
                    }
                }
                gains[i] = total
            }
            self.cumulativeGain = gains
        } else {
            self.cumulativeGain = []
        }
    }

    /// A lead-in followed by `route`, as one route: the ring sees one path.
    public static func chain(_ leadIn: RouteGeometry, before route: RouteGeometry) -> RouteGeometry {
        var lead = leadIn.points
        if let end = lead.last, let start = route.points.first, end.distance(to: start) < 1 { lead.removeLast() }
        return RouteGeometry(points: lead + route.points,
                             elevations: Array(repeating: nil, count: lead.count) + route.elevations,
                             navPoints: lead + route.navPoints)
    }

    // MARK: Stats

    /// Total length, metres.
    public var length: Double { cumulative.last ?? 0 }
    public var hasElevation: Bool { !cumulativeGain.isEmpty }
    /// Total climb, metres (nil without elevation data).
    public var totalGain: Double? { cumulativeGain.last }
    /// Total descent, metres, with the same 3 m hysteresis as the climb (nil without elevation).
    public var totalLoss: Double? {
        guard hasElevation else { return nil }
        var ref: Double?
        var total = 0.0
        for e in elevations.compactMap({ $0 }) {
            if let r = ref {
                if r - e >= 3 { total += r - e; ref = e } else if e - r >= 3 { ref = e }
            } else {
                ref = e
            }
        }
        return total
    }

    // MARK: Along-route geometry

    /// Index of the segment (points[i] → points[i+1]) containing distance `along`.
    public func segmentIndex(at along: Double) -> Int {
        guard points.count > 1 else { return 0 }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= along { lo = mid } else { hi = mid }
        }
        return min(lo, points.count - 2)
    }

    /// The point `along` metres from the start (clamped to the route).
    public func coordinate(at along: Double) -> GeoPoint {
        guard points.count > 1 else { return points.first ?? GeoPoint(0, 0) }
        let d = min(max(0, along), length)
        let i = segmentIndex(at: d)
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? (d - cumulative[i]) / segLen : 0
        let a = points[i], b = points[i + 1]
        return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t)
    }

    /// Direction of travel (degrees, 0 = north) at `along`.
    public func heading(at along: Double) -> Double {
        guard points.count > 1 else { return 0 }
        var i = segmentIndex(at: min(max(0, along), length))
        // Skip zero-length segments (duplicate points).
        while i < points.count - 2, cumulative[i + 1] - cumulative[i] < 0.5 { i += 1 }
        return points[i].bearing(to: points[i + 1])
    }

    /// Climb still ahead from `along` (nil without elevation data).
    public func remainingGain(from along: Double) -> Double? {
        guard let total = totalGain, points.count > 1 else { return nil }
        let i = segmentIndex(at: min(max(0, along), length))
        return max(0, total - cumulativeGain[i])
    }

    /// Result of snapping a position onto the route.
    public struct Match: Equatable, Sendable {
        /// Distance along the route of the snapped point, metres.
        public let along: Double
        /// Distance from the position to the route, metres.
        public let distance: Double
        /// Segment index of the snapped point (points[segment] → points[segment+1]).
        public let segment: Int
        public let coordinate: GeoPoint
    }

    /// Snap `c` onto the nearest segment whose span overlaps `range` (metres along the route; the
    /// whole route by default). Uses a local planar projection — accurate to well under a metre at
    /// guidance scales.
    public func match(_ c: GeoPoint, in range: ClosedRange<Double>? = nil) -> Match? {
        guard points.count > 1 else { return nil }
        let kx = cos(c.lat * .pi / 180) * 111_320.0
        let ky = 110_540.0
        func xy(_ p: GeoPoint) -> (Double, Double) {
            ((p.lon - c.lon) * kx, (p.lat - c.lat) * ky)
        }
        var best: Match?
        var bestD2 = Double.greatestFiniteMagnitude
        var i = range.map { segmentIndex(at: max(0, $0.lowerBound)) } ?? 0
        let upper = range?.upperBound ?? .greatestFiniteMagnitude
        while i < points.count - 1 {
            if cumulative[i] > upper { break }
            let (ax, ay) = xy(points[i]), (bx, by) = xy(points[i + 1])
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / len2)) : 0
            let px = ax + t * dx, py = ay + t * dy
            let d2 = px * px + py * py
            if d2 < bestD2 {
                bestD2 = d2
                let along = cumulative[i] + t * (cumulative[i + 1] - cumulative[i])
                let a = points[i], b = points[i + 1]
                best = Match(along: along, distance: sqrt(d2), segment: i,
                             coordinate: GeoPoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t))
            }
            i += 1
        }
        return best
    }
}

// MARK: - Directions along the route (matched engine, docs/MAP_MATCHING_SPEC.md §5.1)

extension RouteGeometry {
    /// The bearing of the chord from `from` to `to` metres along the route (both clamped to it), or
    /// nil when the chord is under half a metre: a hairpin folded on itself, or a zero-length stretch.
    public func chordBearing(from: Double, to: Double) -> Double? {
        guard points.count > 1 else { return nil }
        let a = coordinate(at: from), b = coordinate(at: to)
        guard a.distance(to: b) >= 0.5 else { return nil }
        return a.bearing(to: b)
    }

    /// The route's direction at `along`, over a window of `window` metres kept inside `range` (the
    /// whole route by default): centred on `along` when it fits, pushed in from an end otherwise.
    /// Measured along the route, never per segment, as GPX files have zero-length segments.
    public func direction(at along: Double, over window: Double, within range: ClosedRange<Double>? = nil) -> Double? {
        let r = range ?? 0...length
        let w = min(window, r.upperBound - r.lowerBound)
        guard w >= 1 else { return nil }
        var lo = max(r.lowerBound, along - w / 2)
        let hi = min(r.upperBound, lo + w)
        lo = max(r.lowerBound, hi - w)
        return chordBearing(from: lo, to: hi)
    }

    /// How much the route turns back at `along`: the angle, 0…180°, between its direction over the
    /// `span` metres before and after. Over ~120° the route doubles back (an out-and-back's tip, a
    /// hairpin), and the two sides are different passes for the matcher.
    public func reversal(at along: Double, span: Double = 15) -> Double {
        guard let before = chordBearing(from: along - span, to: along),
              let after = chordBearing(from: along, to: along + span) else { return 0 }
        return abs(GeoPoint.angleDelta(from: before, to: after))
    }

    /// The same route ridden the other way.
    public func reversed() -> RouteGeometry {
        RouteGeometry(points: points.reversed(), elevations: elevations.reversed(), navPoints: navPoints.reversed())
    }

    /// The route from `along` metres on, for a ride that rejoins it there (docs/APP_SPEC.md M17): the
    /// point there (with no elevation of its own), then the points after it. The whole route at or
    /// before its start; nil at or past its end. The ring navigates the same points.
    public func suffix(from along: Double) -> RouteGeometry? {
        guard points.count > 1 else { return nil }
        guard along > 0 else { return self }
        guard along < length else { return nil }
        let i = segmentIndex(at: along)
        let rest = Array(points[(i + 1)...])
        return RouteGeometry(points: [coordinate(at: along)] + rest,
                             elevations: [nil] + Array(elevations[(i + 1)...]))
    }
}
