import Foundation

/// Riding the route the wrong way (docs/MAP_MATCHING_SPEC.md §8): a state machine fed by the route
/// matcher on every accepted fix. It compares the rider's movement over the last ~40 m with the route's
/// direction where they are, and confirms only when their position along the route goes backwards too,
/// so GPS noise, a stop at a light or a switchback doesn't set it off.
public struct WrongWayDetector: Sendable {
    public enum State: String, Sendable, Codable {
        /// Riding the route the right way (or no idea yet).
        case none
        /// The movement opposes the route; not confirmed yet. Freezes the step sync.
        case suspected
        /// Warn: the ring shows the U-turn, the phone offers to invert the route.
        case confirmed
        /// Confirmed, and the rider chose to ignore it: silent until the episode ends.
        case ignored
    }

    public struct Parameters: Sendable {
        /// Seconds into the ride before it can start.
        public var startAfter = 20.0
        /// Slower than this, the state is kept as it is (stopped at a light).
        public var minimumSpeed = 1.0
        /// The movement is measured over this + the working accuracy…
        public var window = 40.0
        /// …and must be at least this + the working accuracy long.
        public var minimumLength = 20.0
        /// cos(movement, route) at or under this: against the route.
        public var enter = -0.5
        /// Another pass of the route within the leave distance with cos at or above this: the rider is
        /// on that pass (an out-and-back's other leg), not riding the wrong way.
        public var otherLeg = 0.5
        /// cos at or above this, on `exitFixes` fixes in a row: going the right way again.
        public var exit = 0.4
        public var exitFixes = 2
        /// Confirmation: along the route dropped by this share of the distance ridden…
        public var dropShare = 0.5
        /// …over at least this much riding…
        public var dropDistance = 40.0
        /// …on this many evaluations, this far apart.
        public var confirmEvaluations = 2
        public var confirmSpacing = 3.0
        /// Along the route this far past the lowest point of the episode: going forward again.
        public var forwardExit = 30.0
        public init() {}
    }

    /// What the matcher knows on one accepted fix.
    public struct Input: Sendable {
        public var time: Double
        /// m/s, from the fix or the odometer.
        public var speed: Double
        /// The matcher's status is on (or leaving) the route.
        public var onRoute: Bool
        /// Far enough into the ride and past any lead-in.
        public var eligible: Bool
        /// Metres along the route of the best candidate, and the matcher's odometer.
        public var along: Double
        public var odometer: Double
        /// cos between the movement and the route at the best candidate; nil without a movement vector.
        public var cos: Double?
        /// Another pass of the route nearby agrees with the movement.
        public var otherLeg: Bool
        /// cos between the GPS course and the route, when the course is valid and fast enough.
        public var courseCos: Double?
    }

    public var parameters: Parameters
    public private(set) var state = State.none
    /// When the current episode started (`fix.time`).
    public private(set) var since: Double?

    /// (odometer, along) of recent fixes on the route, to measure how along moves as the rider rides.
    var history: [(odometer: Double, along: Double)] = []
    var lowestAlong = 0.0
    var forwardFixes = 0
    var evaluations = 0
    var lastEvaluation: Double?

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// True while the step sync must hold still: anything but `none`.
    public var isActive: Bool { state != .none }

    public mutating func update(_ input: Input) {
        if input.onRoute {
            history.append((input.odometer, input.along))
            if let first = history.firstIndex(where: { input.odometer - $0.odometer <= 300 }), first > 0 {
                history.removeFirst(first)
            }
        }
        guard input.onRoute else {                  // off the route: the pointer takes over
            end()
            history.removeAll()                     // back on it, along starts over from there
            return
        }
        if state != .none {
            if input.along > lowestAlong + parameters.forwardExit { end(); return }
            lowestAlong = min(lowestAlong, input.along)
        }
        guard input.eligible, input.speed >= parameters.minimumSpeed, let c = input.cos else { return }

        switch state {
        case .none:
            guard c <= parameters.enter, !input.otherLeg else { return }
            state = .suspected
            since = input.time
            lowestAlong = input.along
            evaluations = 0
            lastEvaluation = nil
            forwardFixes = 0
            confirm(input, c)
        case .suspected, .confirmed, .ignored:
            if max(c, input.courseCos ?? -1) >= parameters.exit {
                forwardFixes += 1
                if forwardFixes >= parameters.exitFixes { end(); return }
            } else {
                forwardFixes = 0
            }
            if state == .suspected { confirm(input, c) }
        }
    }

    /// The rider chose "Ignore": silent until this episode ends.
    public mutating func ignore() {
        if state == .confirmed || state == .suspected { state = .ignored }
    }

    mutating func confirm(_ input: Input, _ c: Double) {
        guard c <= parameters.enter, !input.otherLeg, alongDropped(input) else { return }
        if let last = lastEvaluation, input.time - last < parameters.confirmSpacing { return }
        evaluations += 1
        lastEvaluation = input.time
        if evaluations >= parameters.confirmEvaluations { state = .confirmed }
    }

    /// Along went down by at least `dropShare` of what was ridden over the last `dropDistance` or more.
    func alongDropped(_ input: Input) -> Bool {
        guard let ref = history.last(where: { input.odometer - $0.odometer >= parameters.dropDistance }) else {
            return false
        }
        let ridden = input.odometer - ref.odometer
        return ref.along - input.along >= parameters.dropShare * ridden
    }

    mutating func end() {
        state = .none
        since = nil
        evaluations = 0
        lastEvaluation = nil
        forwardFixes = 0
    }
}
