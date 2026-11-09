import Foundation

/// Where the rider is on the route, fix by fix: the "matched" engine (docs/MAP_MATCHING_SPEC.md §4–§7).
///
/// Every accepted fix is projected onto the whole route. Each stretch of route passing near the rider
/// (a "pass") gives one candidate, scored on distance, direction of travel and continuity with the last
/// confident match. The best candidate says how far along the route the rider is; how far the route is
/// says whether they are on it (with hysteresis); the candidates also feed the wrong-way detector.
/// Pure and deterministic: timers run on `fix.time`, so a recorded ride replays exactly.
public struct RouteMatcher: Sendable {

    public struct Parameters: Sendable {
        // §4 Inputs
        public var maxAccuracy = 40.0
        public var accuracyWindow = 5
        public var minimumAccuracy = 5.0
        public var vMax = 25.0
        // §5.2 Candidates
        public var passMinimum = 40.0
        public var passFactor = 2.5
        public var reversalSpan = 15.0
        public var reversalAngle = 120.0
        public var maxCandidates = 8
        // §5.3 Scores
        public var tauMinimum = 20.0
        public var tauFactor = 1.5
        public var directionWindow = 20.0...60.0
        public var sigmaBase = 25.0
        public var sigmaPerMetre = 0.25
        public var gapGrace = 3.0
        // §5.4 Tracking and confidence
        public var trackingTimeout = 30.0
        public var gateSigmas = 3.0
        public var conflictFixes = 3
        public var marginRatio = 0.5
        // §5.5 Route status
        public var leaveMinimum = 30.0
        public var leaveFactor = 2.0
        public var rejoinExtra = 15.0
        public var rejoinMinimum = 15.0
        public var rejoinShare = 0.75
        public var leaveSeconds = 5.0
        public var leaveFarFixes = 2
        public var rejoinSeconds = 3.0
        public var rejoinFixes = 2
        public var joinAligned = 0.7
        public var joinAnywhere = 0.75
        public var joinAnywhereFixes = 2
        public var joinReversed = 0.25
        public var joinReversedSeconds = 5.0
        public var startWindow = 50.0
        public var leadInMargin = 15.0
        // §7 Arrival and coverage
        public var coverageGap = 100.0
        public var coverageDirection = 0.5
        public var arrivalRadius = 50.0
        public var arrivalCoverage = 0.10
        /// On a loop (its end within `startWindow` of its start), the share of the whole loop: a rider
        /// who sets off on the loop's last stretch, heading for its start, hasn't finished it.
        public var loopArrivalCoverage = 0.5
        public init() {}
    }

    /// What the guidance is told. `leaving` reports as `on` and `hold` is a fix the matcher ignored.
    public enum Status: String, Sendable, Codable { case on, off, rejoining, hold }

    /// One pass of the route near the rider.
    public struct Candidate: Equatable, Sendable {
        /// Metres along the route.
        public var along: Double
        /// Metres from the fix.
        public var distance: Double
        public var point: GeoPoint
        public var segment: Int
        /// The stretch of route (metres along) of this candidate's pass.
        public var pass: ClosedRange<Double>
        /// The route's bearing here, within the pass.
        public var direction: Double?
        public var sDist = 1.0
        public var sDir: Double?
        /// Continuity (or, before the first confident match, the prior that favours the start).
        public var sProg: Double?
        /// Along minus where continuity expects the rider (metres); nil without a confident match.
        public var error: Double?
        public var p = 0.0
    }

    public struct Result: Equatable, Sendable {
        public var status = Status.off
        /// This fix went through the gate.
        public var accepted = false
        public var best: Candidate?
        /// By score, best first; at most `maxCandidates`.
        public var candidates: [Candidate] = []
        public var confident = false
        /// One candidate, or the best clearly ahead of the runner-up.
        public var unambiguous = false
        /// Metres to the nearest point of the route anywhere.
        public var distanceToRoute = Double.infinity
        public var travel: TravelDirection.Estimate?
        /// Share of the route (from where the rider joined it; on a loop, of all of it) ridden the right
        /// way, 0…1.
        public var coverage = 0.0
        public var arrived = false
        /// The rider has been on the route.
        public var joined = false
        public var wrongWay = WrongWayDetector.State.none
        /// Working accuracy (median of the last fixes), metres.
        public var accuracy = 0.0
    }

    public let route: RouteGeometry
    public var parameters: Parameters
    /// Metres of lead-in chained before the route: no joining mid-route until it's ridden.
    public let leadInLength: Double
    /// "Start at the nearest point": join anywhere, and lead there.
    public let joinNearest: Bool
    /// The route ends where it starts.
    let isLoop: Bool

    public private(set) var last = Result()
    public private(set) var wrongWay: WrongWayDetector

    enum Phase: Equatable {
        case off
        case rejoining(since: Double, fixes: Int)
        case on
        case leaving(since: Double, farFixes: Int)
    }

    struct Anchor: Equatable {
        var along: Double
        var odometer: Double
        var time: Double
        var gaps: Double
    }

    var phase = Phase.off
    var joined = false
    var joinAlong: Double?
    /// The furthest confident along on the route (for the lead-in rule).
    var progressAlong = 0.0
    var anchor: Anchor?
    var everConfident = false
    var conflictStreak = 0
    var lastAccepted: (point: GeoPoint, accuracy: Double, time: Double)?
    public private(set) var odometer = 0.0
    var accuracies: [Double] = []
    var travel = TravelDirection()
    var alignedStreak = 0
    var reversedSince: Double?
    /// The ride began at the route's end (within `startWindow` of it, before moving `startWindow`).
    var beganAtEnd = false
    var covered: [ClosedRange<Double>] = []
    var coverFrom: Double?
    var startTime: Double?

    public init(route: RouteGeometry, parameters: Parameters = Parameters(), leadInLength: Double = 0,
                joinNearest: Bool = false) {
        self.route = route
        self.parameters = parameters
        self.leadInLength = leadInLength
        self.joinNearest = joinNearest
        isLoop = route.points.count > 1
            && route.points[0].distance(to: route.points[route.points.count - 1]) <= parameters.startWindow
        wrongWay = WrongWayDetector()
    }

    /// A matcher for `route` already on it at `along`, carrying on the rider's movement from `previous`:
    /// the route was inverted mid-ride (docs/MAP_MATCHING_SPEC.md §9.3).
    public init(continuing previous: RouteMatcher, on route: RouteGeometry, at along: Double) {
        self.init(route: route, parameters: previous.parameters)
        lastAccepted = previous.lastAccepted
        odometer = previous.odometer
        accuracies = previous.accuracies
        travel = previous.travel
        startTime = previous.startTime
        phase = .on
        joined = true
        joinAlong = along
        progressAlong = along
        everConfident = true
        anchor = Anchor(along: along, odometer: odometer, time: lastAccepted?.time ?? 0, gaps: 0)
        coverFrom = along
        last.status = .on
        last.joined = true
        last.accuracy = previous.last.accuracy
    }

    /// The rider chose "Ignore" on a wrong-way warning.
    public mutating func ignoreWrongWay() {
        wrongWay.ignore()
        last.wrongWay = wrongWay.state
    }

    // MARK: - Per fix

    public mutating func update(_ fix: RideFix) -> Result {
        guard route.points.count > 1 else { return last }
        let here = fix.point
        let accuracy = fix.horizontalAccuracy
        if accuracy < 0 || accuracy > parameters.maxAccuracy || (lastAccepted.map { fix.time <= $0.time } ?? false) {
            last.status = .hold
            last.accepted = false
            last.arrived = false
            return last
        }

        // §4: odometer, gaps, working accuracy, travel direction.
        startTime = startTime ?? fix.time
        var speed = max(fix.speed, 0)
        if let previous = lastAccepted {
            let d = previous.point.distance(to: here)
            let dt = fix.time - previous.time
            if d <= parameters.vMax * dt + previous.accuracy + accuracy { odometer += d }
            if fix.speed < 0, dt > 0 { speed = d / dt }
            if var a = anchor { a.gaps += max(0, dt - parameters.gapGrace); anchor = a }
        }
        lastAccepted = (here, accuracy, fix.time)
        accuracies.append(accuracy)
        if accuracies.count > parameters.accuracyWindow { accuracies.removeFirst() }
        let a = max(parameters.minimumAccuracy, Self.median(accuracies))
        travel.add(here, accuracy: accuracy, time: fix.time)
        var heading = travel.estimate()
        if heading == nil, fix.speed >= 2, fix.course >= 0 {
            heading = TravelDirection.Estimate(bearing: fix.course, length: 0)
        }
        let leave = max(parameters.leaveMinimum, parameters.leaveFactor * a)
        let rejoin = min(max(a + parameters.rejoinExtra, parameters.rejoinMinimum), parameters.rejoinShare * leave)

        // §5.2–5.4: candidates, scores, tracking gate, confidence. The anchor (the last confident or
        // joined match) always scores continuity; it gates, as a hard rule, only while tracking: on the
        // route and recent.
        var all = candidates(near: here)
        let dMin = all.first?.distance ?? .infinity
        if !joined, odometer <= parameters.startWindow,
           all.contains(where: { $0.along >= route.length - parameters.startWindow && $0.distance < rejoin }) {
            beganAtEnd = true
        }
        score(&all, heading, a, anchor: anchor)
        var cands = all
        var gateFailed = false
        let onRouteBefore = phase == .on || { if case .leaving = phase { return true } else { return false } }()
        if let an = anchor, onRouteBefore, fix.time - an.time <= parameters.trackingTimeout {
            let limit = parameters.gateSigmas * sigma(an)
            let kept = all.filter { abs($0.error ?? 0) <= limit }
            let nearestKept = all.first.map { n in kept.contains { $0.along == n.along } } ?? true
            let keptBest = kept.max { $0.p < $1.p }
            conflictStreak = !nearestKept && (keptBest?.distance ?? .infinity) > rejoin ? conflictStreak + 1 : 0
            if conflictStreak >= parameters.conflictFixes, let nearest = all.first {
                // Continuity keeps pointing away from where the rider plainly is (a shortcut): start over
                // from the nearest pass, the most continuous of those as near.
                let ties = all.filter { $0.distance <= nearest.distance + 5 }
                let pick = ties.min { abs($0.error ?? 0) < abs($1.error ?? 0) } ?? nearest
                anchor = Anchor(along: pick.along, odometer: odometer, time: fix.time, gaps: 0)
                conflictStreak = 0
                score(&all, heading, a, anchor: anchor)
                cands = all
            } else if kept.isEmpty {
                gateFailed = true
            } else {
                cands = kept
            }
        }
        cands.sort { $0.p > $1.p }
        var best = cands.first
        if !joined, let start = cands.first(where: { $0.along <= parameters.startWindow && $0.distance < rejoin }) {
            best = start                            // §5.5: the ride begins at the start, where a loop's end is as near
        }
        let unambiguous = best.map { b in
            cands.allSatisfy { $0.along == b.along || $0.p / b.p <= parameters.marginRatio }
        } ?? false
        let confident = best.map { $0.distance <= rejoin } ?? false && unambiguous && !gateFailed

        // §5.5: route status.
        if let b = best, (b.sDir ?? 0) >= parameters.joinAnywhere { alignedStreak += 1 } else { alignedStreak = 0 }
        let allowed = best.map { joinAllowed($0, time: fix.time) } ?? false
        switch phase {
        case .off:
            guard let b = best, b.distance < rejoin, allowed else { break }
            if !joined && b.along <= parameters.startWindow {
                becomeOn(b)                         // at the start: at once, as the official app does
            } else {
                phase = .rejoining(since: fix.time, fixes: 1)
            }
        case .rejoining(let since, let fixes):
            if let b = best, b.distance < rejoin, allowed {
                if !joined && b.along <= parameters.startWindow
                    || fix.time - since >= parameters.rejoinSeconds && fixes + 1 >= parameters.rejoinFixes {
                    becomeOn(b)
                } else {
                    phase = .rejoining(since: since, fixes: fixes + 1)
                }
            } else {
                phase = .off
            }
        case .on:
            if dMin > leave { phase = .leaving(since: fix.time, farFixes: dMin > 2 * leave ? 1 : 0) }
        case .leaving(let since, let far):
            if dMin <= leave {
                phase = .on
            } else {
                let farFixes = dMin > 2 * leave ? far + 1 : 0
                if fix.time - since >= parameters.leaveSeconds || farFixes >= parameters.leaveFarFixes {
                    phase = .off                    // tracking ends; the anchor still scores the rejoin
                    conflictStreak = 0
                } else {
                    phase = .leaving(since: since, farFixes: farFixes)
                }
            }
        }
        let onRoute = phase == .on || { if case .leaving = phase { return true } else { return false } }()

        if confident, let b = best {
            anchor = Anchor(along: b.along, odometer: odometer, time: fix.time, gaps: 0)
            everConfident = true
        }

        // §7: coverage and arrival.
        if confident, onRoute, let b = best {
            progressAlong = max(progressAlong, b.along)
            if (b.sDir ?? 1) >= parameters.coverageDirection {
                if let from = coverFrom, b.along > from, b.along - from <= parameters.coverageGap {
                    cover(from...b.along)
                }
                coverFrom = b.along
            } else {
                coverFrom = nil
            }
        }
        let span = max(1, isLoop ? route.length : route.length - (joinAlong ?? 0))
        let coverage = min(1, covered.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } / span)
        let arrived = phase == .on && confident && best.map { route.length - $0.along <= parameters.arrivalRadius } == true
            && coverage >= (isLoop ? parameters.loopArrivalCoverage : parameters.arrivalCoverage)

        // §8: wrong way.
        var input = WrongWayDetector.Input(
            time: fix.time, speed: speed, onRoute: onRoute,
            eligible: fix.time - (startTime ?? fix.time) >= wrongWay.parameters.startAfter
                && (best?.along ?? 0) >= leadInLength,
            along: best?.along ?? 0, odometer: odometer, cos: nil, otherLeg: false, courseCos: nil)
        if let b = best, let v = travel.vector(over: wrongWay.parameters.window + a),
           v.length >= wrongWay.parameters.minimumLength + a,
           let rd = route.direction(at: b.along, over: v.length, within: b.pass) {
            input.cos = Self.cosine(v.bearing, rd)
            input.otherLeg = all.contains { c in
                c.along != b.along && c.distance < leave
                    && (route.direction(at: c.along, over: v.length, within: c.pass)
                        .map { Self.cosine(v.bearing, $0) >= wrongWay.parameters.otherLeg } ?? false)
            }
        }
        if fix.speed >= 2, fix.course >= 0, let rd = best?.direction {
            input.courseCos = Self.cosine(fix.course, rd)
        }
        wrongWay.update(input)

        let status: Status
        switch phase {
        case .off: status = .off
        case .rejoining: status = .rejoining
        case .on, .leaving: status = .on
        }
        last = Result(status: status, accepted: true, best: best, candidates: cands, confident: confident,
                      unambiguous: unambiguous, distanceToRoute: dMin, travel: heading, coverage: coverage,
                      arrived: arrived && !wrongWay.isActive, joined: joined, wrongWay: wrongWay.state,
                      accuracy: a)
        return last
    }

    /// Joining (or rejoining) the route at `b` is a decision on where the rider is: it anchors
    /// continuity, which is what tells the laps of a circuit apart from then on.
    mutating func becomeOn(_ b: Candidate) {
        phase = .on
        if !joined {
            joined = true
            joinAlong = b.along
        }
        coverFrom = nil
        if let fixTime = lastAccepted?.time {
            anchor = Anchor(along: b.along, odometer: odometer, time: fixTime, gaps: 0)
            everConfident = true
        }
    }

    /// §5.5: whether the rider may join the route at `b` now.
    mutating func joinAllowed(_ b: Candidate, time: Double) -> Bool {
        if let s = b.sDir {
            if s >= parameters.joinAligned {
                reversedSince = nil
            } else if s <= parameters.joinReversed {
                // Riding along the route the wrong way: join after a while, the wrong-way warning follows.
                reversedSince = reversedSince ?? time
                if time - (reversedSince ?? time) < parameters.joinReversedSeconds { return false }
            } else {
                reversedSince = nil
                return false                        // crossing it
            }
        }                                           // no direction (noise, a stop): keep what was known
        if leadInLength > 0, progressAlong < leadInLength, b.along > leadInLength + parameters.leadInMargin {
            return false                            // still on the lead-in
        }
        if !joined {
            // Riding it backwards joins only for a ride that began at its end: a loop ridden the other
            // way round, a route loaded the wrong way (the wrong-way warning offers to invert it). Not
            // on the way to the start along its first stretch: the rider turns round there.
            if reversedSince != nil { return beganAtEnd || joinNearest }
            return b.along <= parameters.startWindow || joinNearest || alignedStreak >= parameters.joinAnywhereFixes
        }
        return true
    }

    // MARK: - Candidates and scores

    /// §5.2: one candidate per pass of the route near `p`, nearest first.
    func candidates(near p: GeoPoint) -> [Candidate] {
        let pts = route.points, cum = route.cumulative
        let n = pts.count
        let kx = cos(p.lat * .pi / 180) * 111_320.0, ky = 110_540.0
        var ds = [Double](repeating: .infinity, count: n - 1)
        var ts = [Double](repeating: 0, count: n - 1)
        var ax = (pts[0].lon - p.lon) * kx, ay = (pts[0].lat - p.lat) * ky
        for i in 0..<(n - 1) {
            let bx = (pts[i + 1].lon - p.lon) * kx, by = (pts[i + 1].lat - p.lat) * ky
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / len2)) : 0
            let px = ax + t * dx, py = ay + t * dy
            ds[i] = (px * px + py * py).squareRoot()
            ts[i] = t
            ax = bx; ay = by
        }
        let dMin = ds.min() ?? .infinity
        let reach = max(parameters.passMinimum, parameters.passFactor * dMin)

        var result: [Candidate] = []
        func add(_ segment: Int, _ first: Int, _ lastSegment: Int) {
            let t = ts[segment]
            let a = pts[segment], b = pts[segment + 1]
            result.append(Candidate(along: cum[segment] + t * (cum[segment + 1] - cum[segment]),
                                    distance: ds[segment],
                                    point: GeoPoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t),
                                    segment: segment, pass: cum[first]...cum[lastSegment + 1]))
        }
        var i = 0
        while i < n - 1 {
            guard ds[i] <= reach else { i += 1; continue }
            var end = i
            while end + 1 < n - 1 && ds[end + 1] <= reach { end += 1 }
            // Split the run where the route doubles back, at the sharpest vertex of each fold.
            var splits: [Int] = []
            var foldBest: (vertex: Int, angle: Double)?
            if end > i {
                for v in (i + 1)...end {
                    let angle = route.reversal(at: cum[v], span: parameters.reversalSpan)
                    if angle > parameters.reversalAngle {
                        if foldBest == nil || angle > foldBest!.angle { foldBest = (v, angle) }
                    } else if let f = foldBest {
                        splits.append(f.vertex)
                        foldBest = nil
                    }
                }
            }
            if let f = foldBest { splits.append(f.vertex) }
            var first = i
            for vertex in splits + [end + 1] {
                let lastSegment = vertex - 1
                if lastSegment >= first {
                    var nearest = first
                    for s in first...lastSegment where ds[s] < ds[nearest] { nearest = s }
                    add(nearest, first, lastSegment)
                }
                first = vertex
            }
            i = end + 1
        }
        result.sort { $0.distance < $1.distance }
        return Array(result.prefix(parameters.maxCandidates))
    }

    /// §5.3.
    func score(_ cands: inout [Candidate], _ heading: TravelDirection.Estimate?, _ a: Double, anchor: Anchor?) {
        let tau = max(parameters.tauMinimum, parameters.tauFactor * a)
        let window = heading.map { min(max($0.length, parameters.directionWindow.lowerBound),
                                      parameters.directionWindow.upperBound) } ?? parameters.directionWindow.lowerBound
        for k in cands.indices {
            var c = cands[k]
            c.sDist = exp(-c.distance / tau)
            c.direction = route.direction(at: c.along, over: window, within: c.pass)
            if let h = heading {
                c.sDir = c.direction.map { (1 + Self.cosine(h.bearing, $0)) / 2 } ?? 0.5
            } else {
                c.sDir = nil
            }
            if let an = anchor {
                let e = c.along - (an.along + (odometer - an.odometer))
                c.error = e
                let s = sigma(an)
                c.sProg = 1 / (1 + (e / s) * (e / s))
            } else {
                c.error = nil
                c.sProg = everConfident ? nil : 1 - 0.5 * c.along / max(route.length, 1)
            }
            c.p = (0.2 + 0.8 * c.sDist) * (c.sDir.map { 0.4 + 0.6 * $0 } ?? 1) * (c.sProg.map { 0.6 + 0.4 * $0 } ?? 1)
            cands[k] = c
        }
    }

    func sigma(_ an: Anchor) -> Double {
        parameters.sigmaBase + parameters.sigmaPerMetre * (odometer - an.odometer) + parameters.vMax * an.gaps
    }

    mutating func cover(_ range: ClosedRange<Double>) {
        var merged = range
        var rest: [ClosedRange<Double>] = []
        for r in covered {
            if r.upperBound < merged.lowerBound || r.lowerBound > merged.upperBound {
                rest.append(r)
            } else {
                merged = min(r.lowerBound, merged.lowerBound)...max(r.upperBound, merged.upperBound)
            }
        }
        covered = rest + [merged]
    }

    static func cosine(_ a: Double, _ b: Double) -> Double {
        cos(GeoPoint.angleDelta(from: a, to: b) * .pi / 180)
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
