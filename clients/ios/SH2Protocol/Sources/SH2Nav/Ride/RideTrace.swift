import Foundation

/// The record of a ride, one JSON object per line: a `Header`, then one `Entry` per fix. The same
/// fixes through the same ride logic give the same lines.
public enum RideTrace {
    public static let version = 1

    /// What started the ride: enough to rebuild it (`RideEngine.init`).
    public struct Header: Equatable, Sendable, Codable {
        public var trace = RideTrace.version
        public var title: String
        public var points: [[Double]]
        public var navPoints: [[Double]]
        public var instructions: [Instruction]
        /// A routed destination's own steps as they came; absent on any other ride.
        public var routedSteps: [RoutedStep]?
        public var compass: Bool
        public var leadInLength: Double
        public var joinNearest: Bool
        public var metric: Bool
        public var soundOn: Bool
        public var volume: UInt8
        public var cards: UInt16
        public var appVersion: String
        /// `matched` for the matched engine; absent for the classic one (and older traces).
        public var engine: String?

        public struct Instruction: Equatable, Sendable, Codable {
            public var lat: Double
            public var lon: Double
            public var text: String
            public init(lat: Double, lon: Double, text: String) {
                self.lat = lat; self.lon = lon; self.text = text
            }
        }

        public init(engine: RideEngine, title: String, instructions: [(location: NavLocation, text: String)] = [],
                    routedSteps: [RoutedStep] = [], joinNearest: Bool = false, appVersion: String = "") {
            self.title = title
            points = engine.route.points.map { [$0.lat, $0.lon] }
            navPoints = engine.route.navPoints.map { [$0.lat, $0.lon] }
            self.instructions = instructions.map {
                Instruction(lat: $0.location.lat, lon: $0.location.lon, text: $0.text)
            }
            self.routedSteps = routedSteps.isEmpty ? nil : routedSteps
            compass = engine.compassTarget != nil
            leadInLength = engine.leadInLength
            self.joinNearest = joinNearest
            let settings = engine.director?.settings ?? engine.compass?.settings ?? NavDirector.Settings()
            metric = settings.metric
            soundOn = settings.soundOn
            volume = settings.volume
            cards = settings.carouselCards
            self.appVersion = appVersion
            self.engine = engine.engine == .matched ? RideEngine.Engine.matched.rawValue : nil
        }
    }

    /// One ring command, as sent.
    public struct Command: Equatable, Sendable, Codable {
        public var label: String
        public var hex: String
        public var delay: Double

        public init(_ c: NavCommand) {
            label = c.label
            hex = c.data.map { String(format: "%02x", $0) }.joined()
            delay = c.delay
        }
    }

    /// What the ring guidance decided on a fix, before it became bytes.
    public struct Ring: Equatable, Sendable, Codable {
        public var status: String
        public var offThePath: Bool
        public var reachedOrigin: Bool
        public var step: Int
        public var steps: Int
        public var animation: String
        public var animating: Bool
        public var turnStarted: Bool
        public var angle: Int
        public var turnProgress: Int
        public var nextAngle: Int
        public var nextTurnProgress: Int
        public var progress: Int
        public var pointer: Int
        public var distance: Int
        public var nextDistance: Int
        public var instruction: String
        public var description: String
        public var riderBearing: Int
        public var crowBearing: Int
        /// Where the pointer leads while off the path, `[lat, lon]`.
        public var target: [Double]?
        /// The sound and the animations to clear that this fix asked for.
        public var sound: String
        public var remove: [String]

        public init?(_ director: NavDirector?) {
            guard let director, let g = director.guidance else { return nil }
            let d = g.display
            status = String(describing: g.offlineStatus)
            offThePath = g.offThePath
            reachedOrigin = g.hasReachedOrigin
            step = g.currentStepIndex
            steps = g.steps.count
            animation = String(describing: d.currentType)
            animating = d.isStepAnimationNow
            turnStarted = g.turnStarted
            angle = d.thisTurn.relativeTurnAngle
            turnProgress = d.thisTurn.turnProgress
            nextAngle = d.nextTurn.relativeTurnAngle
            nextTurnProgress = d.nextTurn.turnProgress
            progress = d.progress
            pointer = d.bearing
            distance = d.distanceToThisManeuver
            nextDistance = d.distanceToNextManeuver
            instruction = d.deviceInstruction
            description = d.description
            riderBearing = g.bearing.current
            crowBearing = g.bearing.crowFlies
            target = g.offPathDestination.exists ? [g.offPathDestination.lat, g.offPathDestination.lon] : nil
            sound = String(describing: director.lastSound)
            remove = director.lastRemoved.map { String(describing: $0) }
        }
    }

    /// One processed fix: the fix, what the screen shows, what the ring was told and whether the
    /// ride ended there.
    public struct Entry: Equatable, Sendable, Codable {
        public var fix: RideFix?
        public var screen: RideSnapshot
        public var ring: Ring?
        public var cmds: [Command]
        public var arrived: Bool
        /// Matched engine: what the route matcher made of the fix.
        public var match: Match?
        /// Something the rider did, on a line of its own (no fix): `invert`, `ignoreWrongWay`.
        public var event: String?

        public init(fix: RideFix?, engine: RideEngine, commands: [NavCommand], arrived: Bool = false,
                    event: String? = nil) {
            self.fix = fix
            screen = engine.snapshot
            ring = Ring(engine.director)
            cmds = commands.map(Command.init)
            self.arrived = arrived
            match = Match(engine.matcher)
            self.event = event
        }
    }

    /// Matched engine: the matcher's view of one fix (docs/MAP_MATCHING_SPEC.md §10).
    public struct Match: Equatable, Sendable, Codable {
        public var status: String
        public var along: Double?
        public var distance: Double?
        /// Metres to the nearest point of the route anywhere.
        public var toRoute: Double?
        public var confident: Bool
        public var joined: Bool
        /// The three best candidates as `[along, distance, p]`.
        public var candidates: [[Double]]
        /// The rider's direction of travel, degrees.
        public var travel: Double?
        public var wrongWay: String
        public var coverage: Double
        public var arrived: Bool

        public init?(_ matcher: RouteMatcher?) {
            guard let r = matcher?.last else { return nil }
            status = r.status.rawValue
            along = r.best?.along
            distance = r.best?.distance
            toRoute = r.distanceToRoute.isFinite ? r.distanceToRoute : nil
            confident = r.confident
            joined = r.joined
            candidates = r.candidates.prefix(3).map { [$0.along, $0.distance, $0.p] }
            travel = r.travel?.bearing
            wrongWay = r.wrongWay.rawValue
            coverage = r.coverage
            arrived = r.arrived
        }
    }

    /// One line of JSON. Keys are sorted, so the same ride gives the same bytes.
    public static func line<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf",
                                                                      negativeInfinity: "-inf", nan: "nan")
        guard var data = try? encoder.encode(value) else { return nil }
        data.append(0x0a)
        return data
    }
}
