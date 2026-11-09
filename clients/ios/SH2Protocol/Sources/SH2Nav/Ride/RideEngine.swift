import Foundation

/// One GPS fix: what the ride logic reads from a `CLLocation`. Negative `horizontalAccuracy`,
/// `course` or `speed` mean invalid, as in CoreLocation.
public struct RideFix: Equatable, Sendable, Codable {
    public var lat: Double
    public var lon: Double
    public var horizontalAccuracy: Double
    public var course: Double
    public var speed: Double
    /// Seconds, any fixed origin.
    public var time: Double

    public init(lat: Double, lon: Double, horizontalAccuracy: Double = 5, course: Double = -1,
                speed: Double = -1, time: Double = 0) {
        self.lat = lat; self.lon = lon
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course; self.speed = speed; self.time = time
    }

    var point: GeoPoint { GeoPoint(lat, lon) }
}

/// What the Navigating screen shows after a fix.
public struct RideSnapshot: Equatable, Sendable, Codable {
    /// 0…1 along the route.
    public var progress = 0.0
    public var offRoute = false
    /// Metres from the rider to the route (meaningful while `offRoute`).
    public var offRouteDistance = 0.0
    /// The pointer back to the route, degrees off the direction of travel (+ = right); nil until
    /// the direction of travel is known.
    public var offRouteBearing: Int?
    /// The rider has been on the route. Until then, off-route means on the way to its start.
    public var reachedOrigin = false
    /// Next manoeuvre ahead (`.straight` when it's more than `RideEngine.straightBeyond` away).
    public var nextTurn = TurnKind.straight
    /// Metres to `nextTurn`, the number the ring shows: 25 m (destination: 50 m) short of the
    /// manoeuvre itself, as in the official app.
    public var nextTurnDistance = 0.0
    /// A routed destination's text for `nextTurn` (the street); nil for a GPX.
    public var nextTurnText: String?
    public var remainingDistance = 0.0
    /// Climb still ahead (nil when the route has no elevation).
    public var remainingGain: Double?
    /// Ground speed, m/s (nil until the first fix).
    public var speed: Double?
    /// Direction of travel, degrees (GPS course while moving, else the route's direction).
    public var heading = 0.0
    /// Metres actually ridden since start.
    public var distanceRidden = 0.0
    /// Bumps on every processed location fix.
    public var fixCount = 0
    /// Compass: the destination's direction relative to the rider's, degrees (+ = right).
    public var compassBearing = 0.0
    /// Metres left of the lead-in to the route's start; nil when there is none or it's done.
    public var toStart: Double?
    /// Matched engine: riding the route the wrong way (a confirmed warning the rider hasn't ignored).
    /// Nil in the classic engine.
    public var wrongWay: Bool?
    /// Matched engine: the wrong-way warning can offer to invert the route (a GPX ride, lead-in done).
    public var canInvert: Bool?

    public init() {}
}

/// The ride logic of one ride, with no UI or platform in it: every fix goes through the ring
/// guidance (`NavDirector`, or `CompassDirector` as the crow flies), and the screen shows what that
/// guidance decided. As in the official app, where both read the same `SHGuidanceDisplayStatus`, so
/// they can't disagree; the screen only tracks on its own what the ring has no notion of (progress,
/// distance left, speed). `GuidanceController` is the app's adapter around it.
public struct RideEngine: Sendable {
    public let route: RouteGeometry
    /// Ring guidance: a route, or a destination as the crow flies.
    public private(set) var director: NavDirector?
    public private(set) var compass: CompassDirector?
    public private(set) var snapshot = RideSnapshot()

    /// The destination of an "as the crow flies" ride; nil when following a route.
    public let compassTarget: GeoPoint?
    var compassStartDistance: Double?
    /// Length of the lead-in chained before the route (0 = none).
    let leadInLength: Double

    /// Which logic locates the rider on the route.
    public enum Engine: String, Sendable, Codable {
        /// The official app's: the current stretch, a step that only moves forward.
        case classic
        /// The route matcher over the whole route, with the wrong-way warning
        /// (docs/MAP_MATCHING_SPEC.md).
        case matched
    }
    public let engine: Engine
    /// The matched engine's matcher; nil in the classic engine and as the crow flies.
    public private(set) var matcher: RouteMatcher?
    /// A GPX ride (not a routed destination): the route can be inverted on a wrong-way warning.
    public let invertible: Bool
    let joinNearest: Bool

    /// Further than this from the expected stretch, look for the rider on the whole route.
    static let rematchBeyond = 30.0   // metres
    public static let straightBeyond = 1000.0

    var matchedAlong = 0.0
    var lastFix: RideFix?

    /// Guide along `route`.
    /// - `instructions`: a routed destination's instructions (street names on the ring).
    /// - `routedSteps`: a routed destination's own steps, for its turns. Without them, or if they don't
    ///   add up to `route`, the GPX turn detector finds the turns.
    /// - `leadInLength`: length of a lead-in to the route's start already chained into `route`.
    /// - `joinNearest`: join the route at its nearest point instead of its start.
    /// - `engine`: classic by default; the app picks matched unless the rider chose classic.
    public init(route: RouteGeometry, title: String, settings: NavDirector.Settings,
                instructions: [(location: NavLocation, text: String)] = [],
                routedSteps: [RoutedStep] = [],
                leadInLength: Double = 0, joinNearest: Bool = false, engine: Engine = .classic) {
        self.route = route
        compassTarget = nil
        self.leadInLength = leadInLength
        self.engine = engine
        self.joinNearest = joinNearest
        invertible = routedSteps.isEmpty && (instructions.isEmpty || leadInLength > 0)
        var d = RoutedStep.covers(routedSteps, length: route.length)
            ? NavDirector(routed: routedSteps, title: title, settings: settings)
            : NavDirector(points: route.navPoints.map { NavLocation($0.lat, $0.lon) }, title: title,
                          settings: settings, instructions: instructions)
        d.startAtNearestStep = joinNearest
        if engine == .matched {
            d.enableMatching(stepAlong: Self.stepAlong(d.steps, on: route))
            matcher = RouteMatcher(route: route, leadInLength: leadInLength, joinNearest: joinNearest)
        }
        director = d
        reset()
        snapshot.toStart = leadInLength > 0 ? leadInLength : nil
        if engine == .matched { snapshot.wrongWay = false; snapshot.canInvert = false }
    }

    /// "As the crow flies" to `destination`: the ring points at it, no route. `origin` (the rider,
    /// when known) draws a straight line to it on the map.
    public init(compassTo destination: GeoPoint, from origin: GeoPoint?, title: String,
                settings: NavDirector.Settings) {
        route = RouteGeometry(points: [origin ?? destination, destination])
        compassTarget = destination
        leadInLength = 0
        engine = .classic                           // a straight line: nothing to match
        invertible = false
        joinNearest = false
        compass = CompassDirector(destination: NavLocation(destination.lat, destination.lon), title: title,
                                  settings: settings)
        reset()
    }

    private mutating func reset() {
        snapshot.remainingDistance = route.length
        snapshot.remainingGain = route.totalGain
        snapshot.heading = route.heading(at: 0)
        updateNextTurn()
    }

    // MARK: - Ring lifecycle

    public mutating func start(ringConnected: Bool) -> [NavCommand] {
        if compass != nil { return compass?.start(ringConnected: ringConnected) ?? [] }
        return director?.start(ringConnected: ringConnected) ?? []
    }

    /// The ring connected: an intro that couldn't be shown at start goes now.
    public mutating func ringConnected() -> [NavCommand] {
        if compass != nil { return compass?.ringConnected() ?? [] }
        return director?.ringConnected() ?? []
    }

    /// The user ended the ride: clear the ring (on arrival the director already sent its sequence).
    public mutating func stop() -> [NavCommand] {
        var commands: [NavCommand] = []
        if let d = director, !d.completed { commands += director?.stop() ?? [] }
        if let c = compass, !c.completed { commands += compass?.stop() ?? [] }
        return commands
    }

    /// The ring reports its carousel card; on the Navigation card it gets the card's content
    /// (`CarouselController.updateNavigationCard`).
    public mutating func carouselChanged(card: UInt8?) -> [NavCommand] {
        guard director != nil else { return [] }
        director?.carouselOnNavigation = card == NavDirector.navigationCard
        guard let d = director, d.carouselOnNavigation else { return [] }
        return [d.carouselCard()]
    }

    // MARK: - Per fix

    /// One GPS fix: the ring's commands (send them as they are) and, in `snapshot`, what the screen
    /// shows. `compassHeading`: the iPhone compass when reliable, for Compass rides. On arrival the
    /// screen state keeps the previous fix, the ride is over.
    public mutating func update(_ fix: RideFix, compassHeading: Double? = nil) -> NavDirector.Result {
        guard route.points.count > 1 else { return NavDirector.Result() }
        let result = guideRing(fix, compassHeading)
        if !result.arrived { followOnScreen(fix, compassHeading) }
        return result
    }

    /// Feed one fix to the ring guidance — every fix, unfiltered, as the official app does.
    private mutating func guideRing(_ fix: RideFix, _ compassHeading: Double?) -> NavDirector.Result {
        let accuracy = fix.horizontalAccuracy >= 0 ? Int(fix.horizontalAccuracy.rounded()) : 999
        let loc = NavLocation(fix.lat, fix.lon, accuracy: accuracy)
        if compass != nil {
            // The iPhone compass only while slow or stopped; moving, the GPS direction.
            let phone = fix.speed < 1.5 ? compassHeading : nil
            return compass?.update(loc, heading: phone) ?? NavDirector.Result()
        }
        guard var m = matcher else { return director?.update(loc) ?? NavDirector.Result() }
        let r = m.update(fix)
        matcher = m
        let match = navMatch(r)
        return director?.update(loc, match: match, wrongWay: r.wrongWay == .confirmed) ?? NavDirector.Result()
    }

    /// What the guidance is told about a fix. On the way to the route's start (not joined yet, not
    /// "start at the nearest point") the pointer leads to the start, as in the official app.
    func navMatch(_ r: RouteMatcher.Result) -> NavMatch {
        let best = r.best
        let start = route.points[0]
        let target = (r.joined || joinNearest)
            ? best.map { NavLocation($0.point.lat, $0.point.lon) } ?? NavLocation(start.lat, start.lon)
            : NavLocation(start.lat, start.lon)
        return NavMatch(status: r.status, target: target, along: best?.along ?? 0,
                        distance: best?.distance ?? .infinity, confident: r.confident,
                        unambiguous: r.unambiguous, frozen: r.wrongWay != .none, arrived: r.arrived)
    }

    // MARK: - Wrong way (matched engine)

    /// The rider chose "Ignore" on the wrong-way warning: silent until they ride forward again.
    public mutating func ignoreWrongWay() {
        matcher?.ignoreWrongWay()
        snapshot.wrongWay = false
        snapshot.canInvert = false
    }

    /// The same ride on the route turned around, the rider already on it where they are now
    /// (docs/MAP_MATCHING_SPEC.md §9.3), and what clears the ring first. Ride numbers carry on. Nil
    /// unless this is a matched GPX ride placed on the route.
    public func inverted() -> (engine: RideEngine, commands: [NavCommand])? {
        guard engine == .matched, invertible, snapshot.toStart == nil, let director,
              let m = matcher, let best = m.last.best else { return nil }
        let reversed = route.reversed()
        var e = RideEngine(route: reversed, title: director.title, settings: director.settings, engine: .matched)
        let d = director.continuing(on: reversed.navPoints.map { NavLocation($0.lat, $0.lon) })
        e.director = d
        e.director?.enableMatching(stepAlong: Self.stepAlong(d.steps, on: reversed))
        let along = max(0, reversed.length - best.along)
        e.matcher = RouteMatcher(continuing: m, on: reversed, at: along)
        e.matchedAlong = along
        e.lastFix = lastFix
        e.snapshot.distanceRidden = snapshot.distanceRidden
        e.snapshot.speed = snapshot.speed
        e.snapshot.heading = snapshot.heading
        e.snapshot.fixCount = snapshot.fixCount
        e.snapshot.reachedOrigin = true
        e.snapshot.progress = reversed.length > 0 ? min(1, along / reversed.length) : 0
        e.snapshot.remainingDistance = max(0, reversed.length - along)
        e.snapshot.remainingGain = reversed.remainingGain(from: along)
        return (e, director.clearRing())
    }

    /// Where each manoeuvre of `steps` is along `route` (docs/MAP_MATCHING_SPEC.md §6.1): exact for
    /// the GPX detector's turns, projected onto the route for a routing service's steps.
    static func stepAlong(_ steps: [NavStep], on route: RouteGeometry) -> [Double] {
        let n = steps.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        var along = [Double](repeating: 0, count: n)
        along[n - 1] = route.length
        for i in 1..<(n - 1) {
            let previous = along[i - 1]
            var value: Double
            if let index = steps[i].routeIndex, index < route.cumulative.count {
                value = route.cumulative[index]
            } else {
                let e = steps[i].entrance
                let ahead = previous + 1.5 * steps[i - 1].firstDistance + 100
                if let m = route.match(GeoPoint(e.lat, e.lon), in: previous...ahead), m.distance <= 25 {
                    value = m.along
                } else {
                    value = previous + steps[i - 1].firstDistance
                }
            }
            along[i] = min(max(value, previous), route.length)
        }
        return along
    }

    /// The screen's numbers: what the ring guidance decided, plus progress, distance and speed.
    private mutating func followOnScreen(_ fix: RideFix, _ compassHeading: Double?) {
        let here = fix.point
        let goodFix = fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 50

        // Distance ridden + speed.
        if goodFix {
            if let prev = lastFix {
                let d = here.distance(to: prev.point)
                let dt = fix.time - prev.time
                if d < 300 { snapshot.distanceRidden += d }      // ignore GPS jumps
                if fix.speed >= 0 {
                    snapshot.speed = fix.speed
                } else if dt > 0 {
                    snapshot.speed = d / dt
                }
            } else if fix.speed >= 0 {
                snapshot.speed = fix.speed
            }
            lastFix = fix
        }

        if let target = compassTarget {
            followCompass(fix, to: target, compassHeading)
            snapshot.fixCount += 1
            return
        }

        if let r = matcher?.last {
            // Matched engine: the matcher's along, kept only from confident matches on the route.
            followGuidance()
            if !snapshot.offRoute, r.confident, let best = r.best { matchedAlong = best.along }
            followRoute(fix)
            snapshot.wrongWay = r.wrongWay == .confirmed
            snapshot.canInvert = r.wrongWay == .confirmed && invertible && snapshot.toStart == nil
            return
        }

        // Snap onto the route, near where we were (so loops don't jump to the end), falling back
        // to the whole route when the rider isn't near the expected stretch.
        var candidate = route.match(here, in: (matchedAlong - 60)...(matchedAlong + 500))
        if (candidate?.distance ?? .greatestFiniteMagnitude) > Self.rematchBeyond,
           let g = route.match(here), g.distance < (candidate?.distance ?? .greatestFiniteMagnitude) {
            candidate = g
        }
        guard let m = candidate else { return }

        followGuidance()
        if !snapshot.offRoute { matchedAlong = m.along }
        followRoute(fix)
    }

    /// Progress, distance and climb left, heading and the lead-in countdown from `matchedAlong`.
    private mutating func followRoute(_ fix: RideFix) {
        snapshot.progress = route.length > 0 ? min(1, matchedAlong / route.length) : 0
        snapshot.remainingDistance = max(0, route.length - matchedAlong)
        snapshot.remainingGain = route.remainingGain(from: matchedAlong)
        if fix.course >= 0, (snapshot.speed ?? 0) > 1.5 {
            snapshot.heading = fix.course
        } else if !snapshot.offRoute {
            snapshot.heading = route.heading(at: matchedAlong)
        }
        if snapshot.toStart != nil {
            let left = leadInLength - matchedAlong
            snapshot.toStart = left > 15 ? left : nil
        }

        snapshot.fixCount += 1
    }

    /// Compass ride: straight-line distance and direction to the destination.
    private mutating func followCompass(_ fix: RideFix, to target: GeoPoint, _ compassHeading: Double?) {
        let d = fix.point.distance(to: target)
        let start = compassStartDistance ?? max(d, 1)
        compassStartDistance = start
        snapshot.remainingDistance = d
        snapshot.progress = min(1, max(0, 1 - d / start))
        snapshot.nextTurn = .straight
        snapshot.nextTurnDistance = d
        if fix.course >= 0, (snapshot.speed ?? 0) > 1.5 {
            snapshot.heading = fix.course
        } else if let compassHeading {
            snapshot.heading = compassHeading
        }
        snapshot.compassBearing = GeoPoint.angleDelta(from: snapshot.heading, to: fix.point.bearing(to: target))
    }

    /// `PresentationNavigationStateFactory.updateOnNewLocation`: the screen says what the ring says.
    private mutating func followGuidance() {
        guard let g = director?.guidance else { return }
        let ds = g.display
        snapshot.reachedOrigin = g.hasReachedOrigin
        snapshot.offRoute = g.offlineStatus != .onPath
        if snapshot.offRoute {
            snapshot.offRouteDistance = Double(ds.distanceToThisManeuver)
            let pointer = g.offlineStatus == .offPath ? ds.bearing : g.turningOnPathAngle
            snapshot.offRouteBearing = pointer == NavBearing.unknown ? nil : NavMath.normalized(pointer)
        }
        updateNextTurn()
    }

    private mutating func updateNextTurn() {
        guard let d = director, d.steps.count >= 2 else {
            snapshot.nextTurn = .straight
            snapshot.nextTurnDistance = snapshot.remainingDistance
            return
        }
        let index = min((d.guidance?.currentStepIndex ?? 0) + 1, d.steps.count - 1)
        let next = d.steps[index]
        let distance = d.guidance.map { Double($0.display.distanceToThisManeuver) } ?? d.steps[0].firstDistance
        snapshot.nextTurnDistance = distance
        snapshot.nextTurnText = d.turnTexts[index]
        if next.type == NavStepType.destination {
            snapshot.nextTurn = .arrival
        } else if distance > Self.straightBeyond {
            snapshot.nextTurn = .straight
        } else {
            let angle = Double(next.angles.first ?? 0)
            snapshot.nextTurn = TurnKind(turn: angle) ?? (d.routed ? .gentle(angle) : angle > 0 ? .right : .left)
        }
    }
}
