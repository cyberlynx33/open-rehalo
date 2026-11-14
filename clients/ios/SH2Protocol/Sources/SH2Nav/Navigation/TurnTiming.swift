import Foundation

/// When the ring announces a manoeuvre: by the time it takes to reach it, not at a fixed distance,
/// so a rider at 30 km/h gets the arc as far ahead as one at 10 km/h gets it close
/// (docs/APP_SPEC.md M17). Every threshold is `seconds × speed + reactionMargin`, the speed floored
/// at walking pace, so a rider stopped at a light still gets a few metres of notice.
///
/// Phases, by seconds to the manoeuvre: `far` (over a minute: nothing), `upcoming` (60–30 s: the
/// next turn is known, no arc yet), `prepare` (30–14 s: the arc appears and fills), `approach`
/// (14–10 s: still filling), `order` (10 s or less: the arc is full and the turn sound plays).
public struct TurnTiming: Equatable, Sendable {
    /// Slower than this (m/s) counts as this; a negative `CLLocation.speed` means unknown.
    public static let minimumSpeed = 1.0
    /// Metres added to every notice, for the rider's reaction.
    public static let reactionMargin = 7.0
    /// Further ahead than this (seconds) nothing is said about the manoeuvre.
    public static let upcomingSeconds = 60.0
    /// The arc appears, empty, this far ahead.
    public static let prepareSeconds = 30.0
    /// The "prepare" phase ends here; the arc keeps filling.
    public static let prepareEndSeconds = 14.0
    /// The order: full arc and the turn sound.
    public static let orderSeconds = 10.0
    /// Two manoeuvres closer than this many seconds of riding are announced together: the ring
    /// draws the second arc behind the first.
    public static let chainSeconds = 32.0
    /// The OLED's distance runs this many metres short of the manoeuvre, as in the official app.
    public static let oledShortfall = 25.0

    /// Arrival: within this many metres of the route's end…
    public static let arrivalRadius = 40.0
    /// …having ridden more than this share of the route, so a loop doesn't end at its start.
    public static let arrivalMinimumShare = 0.10
    /// The destination's ring starts filling this far from the end.
    public static let arrivalNoticeDistance = 160.0

    public enum Phase: Equatable, Sendable {
        case far, upcoming, prepare, approach, order
    }

    /// The speed the thresholds are scaled by, m/s, never under `minimumSpeed`.
    public let speed: Double

    /// `speed`: the fix's ground speed (`CLLocation.speed`); nil, negative or not a number means
    /// unknown and counts as `minimumSpeed`.
    public init(speed: Double?) {
        let v = speed ?? 0
        self.speed = v.isFinite ? max(v, Self.minimumSpeed) : Self.minimumSpeed
    }

    /// Metres covered in `seconds` at this speed, plus the reaction margin.
    public func distance(forSeconds seconds: Double) -> Double { seconds * speed + Self.reactionMargin }

    public var upcomingDistance: Double { distance(forSeconds: Self.upcomingSeconds) }
    public var prepareDistance: Double { distance(forSeconds: Self.prepareSeconds) }
    public var prepareEndDistance: Double { distance(forSeconds: Self.prepareEndSeconds) }
    public var orderDistance: Double { distance(forSeconds: Self.orderSeconds) }
    /// Manoeuvres closer than this to each other are chained (no reaction margin: it's between them).
    public var chainDistance: Double { Self.chainSeconds * speed }

    public func phase(atDistance d: Double) -> Phase {
        if d <= orderDistance { return .order }
        if d <= prepareEndDistance { return .approach }
        if d <= prepareDistance { return .prepare }
        if d <= upcomingDistance { return .upcoming }
        return .far
    }

    /// The ring's arc, 0…100 (the scale the protocol expects): empty at the prepare distance, full
    /// at the order distance.
    public func progress(atDistance d: Double) -> Int {
        Self.progress(d, from: prepareDistance, to: orderDistance)
    }

    /// The destination's ring, 0…100: empty at the arrival notice, full at the arrival radius.
    public static func arrivalProgress(atDistance d: Double) -> Int {
        progress(d, from: arrivalNoticeDistance, to: arrivalRadius)
    }

    /// 0 at `start` metres and beyond, 100 at `end` metres and closer, linear in between.
    public static func progress(_ d: Double, from start: Double, to end: Double) -> Int {
        guard d.isFinite else { return 0 }
        guard start > end else { return d <= end ? 100 : 0 }
        let p = (start - d) / (start - end) * 100
        return Int(min(100, max(0, p)))
    }
}
