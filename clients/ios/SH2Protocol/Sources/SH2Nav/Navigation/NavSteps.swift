import Foundation

/// `NavigationStep::StepType`.
public enum NavStepType {
    public static let destination = 0
    public static let depart = 1
    public static let uTurn = 8
    public static let standard = 15
    public static let roundabout = 16
    public static let roundaboutClockwise = 17
    public static let roundaboutCounterClockwise = 18
}

/// `smarthalo::NavigationStep` (the fields the GPX flow uses). A step's `path` starts at the
/// previous manoeuvre; its manoeuvre (`entrance`) is where it begins.
public struct NavStep: Equatable, Sendable {
    public var type: Int
    public var angles: [Int]
    public var headingBefore: Int
    public var headingAfter: Int
    public var entrance: NavLocation
    public var exit: NavLocation
    public var mode: Int                       // TransportationMode: 0 cycling, 1 caution
    public var instruction: String             // raw i18n key, e.g. "nav.found.left"
    public var streetName: String
    public var path: [NavLocation]
    public var firstDistance: Double
    public var roundaboutExitDistance: Double = -1
    public var roundaboutExitStreetName = ""
    public var startIndex: Int
    /// Addition: index in the route's points of the vertex this step's manoeuvre is at, when the GPX
    /// turn detector found it (the matched engine reads where the manoeuvre is along the route from it;
    /// `startIndex` can't, as it counts decimated points). Nil for routed steps.
    public var routeIndex: Int? = nil
    /// Addition: the manoeuvre as the routing service typed it (BRouter); nil from the GPX detector
    /// and from Apple's steps, which only have text.
    public var maneuver: RoutedManeuver? = nil

    public var isRoundabout: Bool { type & 0x10 != 0 }

    /// `getInstruction()`: strips one trailing '.'.
    var instructionText: String { instruction.hasSuffix(".") ? String(instruction.dropLast()) : instruction }

    /// `distanceFromPath`.
    func distanceFromPath(_ loc: NavLocation) -> Double {
        if type != NavStepType.destination { return loc.distance(to: ClosestPathLocation(loc, path).location) }
        return loc.distance(to: entrance)
    }

    /// `distanceToStepEnd`.
    func distanceToStepEnd(_ loc: NavLocation) -> Double { ClosestPathLocation(loc, path).distanceRemaining }
}

/// `SHNavigationStepFactory` — GPX points → steps (official "OfflineTurnByTurn").
public enum NavStepFactory {

    /// Which GPX points the original reads: every `<wpt>` and every `<trkpt>` (all tracks and
    /// segments concatenated); `<rte>` is ignored. Waypoints win only when there are strictly more of
    /// them. Only lat/lon are used.
    public static func points(waypoints: [NavLocation], trackPoints: [NavLocation]) -> [NavLocation] {
        waypoints.count > trackPoints.count ? waypoints : trackPoints
    }

    /// `createStepsFromGPX`: one STANDARD step over the whole track, split at every turn, plus a
    /// DESTINATION step. Only types 15 and 0 come out of a GPX.
    public static func steps(from geometry: [NavLocation]) -> [NavStep] {
        guard let first = geometry.first else { return [] }
        let continueKey = "nav.inject.continue.instruction"
        let whole = NavStep(type: NavStepType.standard, angles: [], headingBefore: 0, headingAfter: 0,
                            entrance: first, exit: first, mode: 0,
                            instruction: continueKey, streetName: continueKey,
                            path: geometry, firstDistance: 0, startIndex: 0)
        var steps = stepsWithinStep(whole)
        if steps.isEmpty { steps = [whole] }       // no turn: one step, firstDistance stays 0
        // (The original then tries to make steps[0] a DEPART step, but edits a discarded copy.)
        let total = steps.reduce(0) { $0 + $1.path.count }
        let last = steps[steps.count - 1]
        let end = last.path[last.path.count - 1]
        let arrival = "nav.inject.direct.arrival"
        steps.append(NavStep(type: NavStepType.destination, angles: [], headingBefore: last.headingBefore,
                             headingAfter: 0, entrance: end, exit: end, mode: 0,
                             instruction: arrival, streetName: arrival,
                             path: [end], firstDistance: 0, startIndex: total))
        return steps
    }

    /// `checkForStepWithinStep`.
    static func stepsWithinStep(_ step: NavStep) -> [NavStep] {
        guard step.path.count >= 2 else { return [] }
        let paths = pathSplits(step.path, threshold: 3.0)
        guard let p0 = paths.first else { return [] }
        var first = step
        first.path = p0.points
        first.firstDistance = p0.distance
        var out = [first]
        var startIndex = step.startIndex + p0.points.count
        for p in paths.dropFirst() {
            let angle = p.angle
            let key = angle > 44 ? "nav.found.right" : "nav.found.left"
            let m = p.points[0]
            out.append(NavStep(type: NavStepType.standard, angles: [angle],
                               headingBefore: p.headingBefore, headingAfter: p.headingAfter,
                               entrance: m, exit: m, mode: step.mode, instruction: key, streetName: key,
                               path: p.points, firstDistance: p.distance, startIndex: startIndex,
                               routeIndex: p.vertex))
            startIndex += p.points.count
        }
        return out
    }

    /// `SHPath`.
    struct Path {
        var points: [NavLocation] = []
        /// Addition: index in the detector's input of the apex this path starts at.
        var vertex: Int? = nil
        var headingBefore = 0
        var headingAfter = 0
        /// `getPathAngle()[0]`.
        var angle: Int { NavMath.difference(headingBefore, headingAfter) }
        /// `getPathDistance()`.
        var distance: Double {
            var d = 0.0
            for i in points.indices.dropFirst() { d += points[i - 1].distance(to: points[i]) }
            return d
        }
    }

    /// `StepCreationHelper::checkForPathSplits` — the turn detector. A window A=P[i-1] … B=P[j]
    /// finds the apex with the biggest bend; while the apex is within `threshold` m of either end the
    /// window grows. |turn| ≥ 46° splits the path at the apex. Points skipped by the window are
    /// dropped (the paths are decimated), as in the original.
    static func pathSplits(_ p: [NavLocation], threshold: Double) -> [Path] {
        let n = p.count
        guard n >= 3 else { return [] }
        var result: [Path] = []
        var cur = Path(points: [p[0], p[1]])
        var j = 1
        repeat {
            let i = j
            j = i + 1
            var bA = 0.0, bB = 0.0
            var maxIdx = i                      // not reset between window passes (as in the binary)
            while true {
                let a = p[i - 1], b = p[j]
                var maxDiff = 0
                for k in i..<j {
                    let d = abs(NavMath.difference(Int(a.bearing(to: p[k])), Int(p[k].bearing(to: b))))
                    if d > maxDiff { maxIdx = k; maxDiff = d }
                }
                let m = p[maxIdx]
                let near = m.distance(to: a) < threshold || m.distance(to: b) < threshold
                bA = a.bearing(to: m)
                bB = m.bearing(to: b)
                if !near { break }
                j += 1
                if j >= n { break }
            }
            let angle = NavMath.difference(Int(bA), Int(bB))
            if j < n && abs(angle) >= 46 {
                if result.isEmpty {
                    cur.headingBefore = 0; cur.headingAfter = 0
                    result.append(cur)
                } else {
                    appendPath(&result, cur)
                }
                cur = Path(points: [p[maxIdx]], vertex: maxIdx)
            }
            if j < n { cur.points.append(p[j]) }
        } while j < n - 1
        if cur.points.count >= 2 && !result.isEmpty { appendPath(&result, cur) }
        return result
    }

    /// `StepCreationHelper::createNewPath`: headings = last segment of the previous path / first
    /// segment of the new one.
    static func appendPath(_ paths: inout [Path], _ path: Path) {
        var path = path
        if let prev = paths.last, prev.points.count >= 2, path.points.count >= 2 {
            let k = prev.points.count
            path.headingBefore = Int(Float(prev.points[k - 2].bearing(to: prev.points[k - 1])))
            path.headingAfter = Int(Float(path.points[0].bearing(to: path.points[1])))
        } else {
            path.headingBefore = 0; path.headingAfter = 0
        }
        paths.append(path)
    }

    /// `getStepDescription`.
    static func description(forAngle angle: Int) -> String {
        if angle >= 45 { return "nav.found.right" }
        if angle <= -45 { return "nav.found.left" }
        return "nav.inject.continue.instruction"
    }
}
