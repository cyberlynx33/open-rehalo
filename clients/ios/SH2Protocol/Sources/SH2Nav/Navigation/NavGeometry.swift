import Foundation

// Reverse engineered from the official app's native navigation library (namespace `smarthalo`).
// Function names in the doc comments are the original
// C++ symbols, so each piece can be checked against the binary. Spec: docs/protocol/navigation.md.

/// `smarthalo::Location`: degrees + integer accuracy (m). `999/999` = no location.
public struct NavLocation: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var accuracy: Int

    public init(_ lat: Double, _ lon: Double, accuracy: Int = 0) {
        self.lat = lat; self.lon = lon; self.accuracy = accuracy
    }

    /// `Location()`.
    public static let none = NavLocation(999, 999)

    /// `isExistingLocation()`.
    public var exists: Bool { lat != 999 && lon != 999 }

    /// `calculateDistanceTo`: haversine on a 6 371 km sphere, in metres.
    public func distance(to o: NavLocation) -> Double {
        let la1 = NavMath.rad(lat), lo1 = NavMath.rad(lon), la2 = NavMath.rad(o.lat), lo2 = NavMath.rad(o.lon)
        let s1 = sin((la2 - la1) * 0.5)
        let s2 = sin((lo2 - lo1) * 0.5)
        let a = s1 * s1 + s2 * (cos(la1) * cos(la2) * s2)
        return asin(sqrt(a)) * 12_742_000.0
    }

    /// `calculateBearingTo`: initial bearing rounded to whole degrees, in -180…180 (not 0…360);
    /// due north/south (or the same point) short-cut to 0 / 180.
    public func bearing(to o: NavLocation) -> Double {
        let la1 = lat * Double.pi / 180, lo1 = lon * Double.pi / 180
        let la2 = o.lat * Double.pi / 180, lo2 = o.lon * Double.pi / 180
        let dLon = lo2 - lo1
        let y = cos(la2) * sin(dLon)
        if y == 0 { return la2 > la1 ? 0 : 180 }
        let x = cos(la1) * sin(la2) - (sin(la1) * cos(la2)) * cos(dLon)
        return (atan2(y, x) * 180 / Double.pi).rounded()
    }
}

/// Integer angle helpers of the original (exact, including their edge cases).
public enum NavMath {
    static func rad(_ d: Double) -> Double { d * Double.pi / 180 }
    static func deg(_ r: Double) -> Double { r / Double.pi * 180 }

    /// `calculateDifferenceBetweenAngles(a, b)`: signed turn from a to b in -180…180, + = right.
    public static func difference(_ a: Int, _ b: Int) -> Int {
        var d = b - a
        while d < -180 { d += 360 }
        while d > 180 { d -= 360 }
        return d
    }

    /// `getNormalizedAngleGap(a, b)`: (a − b) folded into 0…360 (360 stays 360).
    public static func gap(_ a: Int, _ b: Int) -> Int {
        var t = a - b
        while t < 0 { t += 360 }
        while t > 360 { t -= 360 }
        return t
    }

    /// `getSmallerAngleGap(a, b)`: 0…180.
    public static func smallerGap(_ a: Int, _ b: Int) -> Int { min(gap(a, b), gap(b, a)) }

    /// `getNormalizedAngle(a)`: -180…180.
    public static func normalized(_ a: Int) -> Int {
        var a = a
        while a > 180 { a -= 360 }
        while a < -180 { a += 360 }
        return a
    }

    /// C `(int)` of a double, without trapping on NaN / infinity like Swift's `Int(_:)`, nor on a
    /// finite value past `Int`'s range (`Double(Int.max)` rounds up to 2^63, where `Int(x)` traps).
    static func trunc(_ x: Double) -> Int {
        guard x.isFinite else { return x.isNaN ? 0 : (x > 0 ? Int.max : Int.min) }
        if x >= Double(Int.max) { return Int.max }
        if x <= Double(Int.min) { return Int.min }
        return Int(x)
    }

    /// `fmaxnm`/`fminnm` clamp (NaN → the other operand) followed by a truncation.
    static func clampTrunc(_ x: Float, _ lo: Float, _ hi: Float) -> Int {
        let a = x.isNaN ? lo : Swift.max(x, lo)
        return Int(Swift.min(a, hi))
    }
}

/// `smarthalo::ClosestPathLocation`: nearest point of a polyline to `user`. The projection runs in
/// raw degree space (no cos(latitude) scaling), as in the original.
struct ClosestPathLocation {
    var location: NavLocation
    /// Index of the next path vertex after `location`.
    var index: Int
    let path: [NavLocation]

    init(_ user: NavLocation, _ path: [NavLocation]) {
        self.path = path
        index = 0
        if path.count <= 1 { location = user; return }
        location = path[0]
        var best = user.distance(to: location)
        for i in 0..<(path.count - 1) {
            let a = path[i], b = path[i + 1]
            let p = Self.project(user, a, b)
            let dP = user.distance(to: p), dA = user.distance(to: a), dB = user.distance(to: b)
            var m = dP < best ? dP : best
            m = dA < m ? dA : m
            m = dB < m ? dB : m
            best = m
            if m == dP { index = i + 1; location = p }
            else if m == dA { index = i; location = a }
            else if m == dB { index = i + 1; location = b }
        }
    }

    /// `locationFromAPoint`.
    static func project(_ p: NavLocation, _ a: NavLocation, _ b: NavLocation) -> NavLocation {
        let dLonP = p.lon - a.lon, dLatP = p.lat - a.lat
        let dLon = b.lon - a.lon, dLat = b.lat - a.lat
        let t = (dLonP * dLon + dLatP * dLat) / (dLon * dLon + dLat * dLat)
        if t < 0 || (a.lon == b.lon && a.lat == b.lat) { return NavLocation(a.lat, a.lon) }
        if t > 1 { return NavLocation(b.lat, b.lon) }
        return NavLocation(a.lat + dLat * t, a.lon + dLon * t)
    }

    /// `distanceRemainingOnPath`: from `location` along the rest of the path.
    var distanceRemaining: Double {
        var sum = 0.0
        var cur = location
        var j = index
        while j < path.count {
            sum += cur.distance(to: path[j])
            cur = path[j]
            j += 1
        }
        return sum
    }
}
