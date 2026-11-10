import Foundation

/// `NavAngleTurns`: one arc on the ring.
public struct NavTurn: Equatable, Sendable {
    public var relativeTurnAngle = -1
    public var relativeToPreviousTurnAngle = -1
    public var relativeToNorthAngle = -1
    public var turnProgress = -1
    public var mode = 0
    public var stepType = NavStepType.depart
    public init() {}
}

/// `SHGuidanceDisplayStatus::AnimationType`.
public enum NavAnimation: Int, Sendable {
    case destination = 0, uTurn, enteringRoundabout, enteredRoundabout, pointer, angle, none
}

/// `SHGuidanceSoundStatus`.
public enum NavSoundStatus: Int, Sendable {
    case returnToPath = 0, progress, turnNow, destination, none
}

/// `OfflineModeStatus`.
public enum NavOfflineStatus: Int, Sendable {
    case onPath = 0, offPath, turningOnPath
}

/// `SHGuidanceDisplayStatus`: what the ring should show after a fix.
public struct NavDisplayStatus: Equatable, Sendable {
    public var typesToRemove: [NavAnimation] = []
    public var roundaboutAngles: [Int] = []
    public var currentType = NavAnimation.none
    public var thisTurn = NavTurn()
    public var nextTurn = NavTurn()
    public var progress = 0
    /// Pointer angle relative to the rider's direction of travel (+ = right), not normalised.
    public var bearing = 999
    public var distanceToThisManeuver = 0
    public var distanceToNextManeuver = 0
    public var incrementCurrentStep = false
    public var isStepAnimationNow = false
    public var description = ""
    public var thisStreetName = ""
    public var roundaboutExitStreetName = ""
    public var deviceInstruction = ""
    public init() {}
}

/// Addition: what the route matcher says about a fix, for the "matched" engine
/// (docs/MAP_MATCHING_SPEC.md §6.3). With one, the matcher decides on/off the route, the step and
/// arrival; `NavGuidance` keeps drawing the ring as the official app does.
public struct NavMatch: Equatable, Sendable {
    public var status: RouteMatcher.Status
    /// Where the pointer and the arcs onto the route lead: the best candidate, or the route's start
    /// while the rider is on their way to it.
    public var target: NavLocation
    /// Metres along the route of the best candidate, and how far it is.
    public var along: Double
    public var distance: Double
    public var confident: Bool
    public var unambiguous: Bool
    /// Wrong way suspected, confirmed or ignored: the step must hold still.
    public var frozen: Bool
    public var arrived: Bool
    /// The matcher's direction of travel (degrees, −180…180), from displacement: it exists at any
    /// speed, where `NavBearing` needs > 3.5 m between fixes. The pointer falls back on it.
    public var travel: Int?

    public init(status: RouteMatcher.Status, target: NavLocation, along: Double = 0, distance: Double = .infinity,
                confident: Bool = false, unambiguous: Bool = false, frozen: Bool = false, arrived: Bool = false,
                travel: Int? = nil) {
        self.status = status; self.target = target; self.along = along; self.distance = distance
        self.confident = confident; self.unambiguous = unambiguous; self.frozen = frozen; self.arrived = arrived
        self.travel = travel
    }
}

/// `smarthalo::SHGuidance` in GPX mode (`NavigationMode.OfflineTurnByTurn`, `processOfflineStepByStep`),
/// with the parts of `NavigationState` and `SHRerouteSystem` it uses. Feed it every GPS fix with
/// `update(_:)`, then read `display`, `sound`, `offlineStatus` and the bearings — that is what the
/// official app's Java side does on each fix (`NavDirector` that part).
///
/// Steps are value copies in the original (`getSteps()` returns a copy every fix), so no per-step
/// state survives a fix — `isStepComplete` can never fire; turns complete through
/// `validateTurnCompleteStateFromBearing`. This keeps that behaviour.
public struct NavGuidance: Sendable {
    public let steps: [NavStep]
    public let destination: NavLocation
    /// `getClosestStepIndexToUser`: the step whose start is nearest to the start location.
    public let closestStepIndexToUser: Int

    public private(set) var display = NavDisplayStatus()
    public var sound = NavSoundStatus.none
    public private(set) var bearing = NavBearing()
    public private(set) var isComplete = false
    public var isNavigating = false

    // NavigationState (offline part)
    public private(set) var currentStepIndex = 0
    var lastOffPathDistance = 0.0
    public private(set) var hasReachedOrigin = false
    public private(set) var offPathDestination = NavLocation.none
    public private(set) var turningOnPathAngle = 0
    public private(set) var offlineStatus = NavOfflineStatus.offPath
    var stepAnimationStarted = false
    public private(set) var turnStarted = false
    var nextTurnAnimationStarted = false

    // SHRerouteSystem
    /// Off the path. The official app sets it right after loading a GPX, so rides start "off path"
    /// (the ring points to the route's start until the rider is within 15 m of it).
    public var offThePath = true
    var lastRerouteTime = -999
    var lastRerouteLocation = NavLocation.none
    var consecutiveRerouteCount = 0
    var ticksAwayFromPath = 0
    /// Seconds clock for the reroute back-off (injectable for tests).
    var now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }

    // Addition: the matched engine (docs/MAP_MATCHING_SPEC.md §6).
    /// Metres along the route of each step's manoeuvre; nil in the classic engine.
    public private(set) var stepAlong: [Double]?
    /// A jump to a step that isn't the next one waits for this many confident fixes…
    static let jumpFixes = 3
    /// …and, backwards, for the rider to be this far before the current step's manoeuvre.
    static let behindMargin = 30.0
    /// This far past the next manoeuvre, the step completes even if the official rule hasn't fired.
    static let forcedCompletionPast = 30.0
    /// The official completion only counts from this far before the manoeuvre.
    static let completionGate = 5.0
    /// Off the route, the step follows the matcher's best candidate within this distance.
    static let offRouteSyncDistance = 95.0
    var pendingStep: Int?
    var pendingCount = 0

    /// `SHGuidance(Location const&, std::string const& gpx)`.
    public init(start: NavLocation, steps: [NavStep]) {
        self.steps = steps
        destination = steps.last?.path.last ?? .none
        closestStepIndexToUser = Self.closestStep(start, steps)
        bearing.previousLocation = NavLocation(start.lat, start.lon, accuracy: start.accuracy)
        offPathDestination = closestLocationOnNearbyPath(start)
        display.description = steps.first?.instructionText ?? ""
        // clearAllBearingData(): bearings and samples reset; the previous location stays the start.
    }

    /// `setCurrentStep` (the app's "start from the nearest step" choice).
    public mutating func setCurrentStep(_ i: Int) {
        currentStepIndex = i
        offPathDestination = closestLocationOnNearbyPath(bearing.previousLocation)
    }

    /// Addition ("start at the nearest point"): join the route on the stretch nearest to `loc`
    /// as if the rider had already been on it, so the pointer and arcs lead to the nearest point of
    /// the route rather than to the start of a stretch (which `setCurrentStep` does).
    public mutating func joinNearestStretch(_ loc: NavLocation) {
        guard steps.count >= 2 else { return }
        var best = 0, bestDistance = Double.greatestFiniteMagnitude
        for i in 0..<(steps.count - 1) {
            let d = steps[i].distanceFromPath(loc)
            if d < bestDistance { best = i; bestDistance = d }
        }
        currentStepIndex = best
        hasReachedOrigin = true
        offPathDestination = closestLocationOnNearbyPath(loc)
    }

    /// `JNI clearTypesToRemove` (the Java side calls it after reading the status).
    public mutating func clearTypesToRemove() { display.typesToRemove.removeAll() }

    // MARK: - Per fix

    /// `SHGuidance::updateState` (offline mode).
    public mutating func update(_ fix: NavLocation) {
        bearing.update(fix)
        processOfflineStepByStep(fix)
    }

    /// Addition (matched engine): where each step's manoeuvre is along the route. Ignored unless there
    /// is one value per step.
    public mutating func enableMatching(stepAlong: [Double]) {
        self.stepAlong = stepAlong.count == steps.count ? stepAlong : nil
    }

    /// Addition (matched engine): the rider is already on the route, `along` metres in, at `loc`: the
    /// route was inverted under them (docs/MAP_MATCHING_SPEC.md §9.3). The step is the one there and
    /// the origin is reached, so the first fix draws the turn ahead, not the route's first one.
    public mutating func placeOnRoute(at along: Double, from loc: NavLocation) {
        guard let stepAlong, steps.count >= 2 else { return }
        var k = 0
        for i in 0..<steps.count where stepAlong[i] <= along { k = i }
        currentStepIndex = min(k, steps.count - 2)
        hasReachedOrigin = true
        offThePath = false
        offlineStatus = .onPath
        offPathDestination = .none
        display.thisTurn.stepType = NavStepType.standard
        let next = steps[currentStepIndex + 1]
        let remaining = ClosestPathLocation(loc, steps[currentStepIndex].path).distanceRemaining
        let short = next.type == NavStepType.destination ? 50.0 : 25.0
        display.distanceToThisManeuver = NavMath.trunc(max(remaining - short, 0))
    }

    /// Addition (matched engine): one fix with what the matcher made of it. A fix the matcher ignored
    /// (`.hold`) only feeds the bearing: the ring keeps what it shows.
    public mutating func update(_ fix: NavLocation, match: NavMatch) {
        bearing.update(fix)
        guard match.status != .hold else { return }
        processOfflineStepByStep(fix, match)
    }

    /// `processOfflineStepByStep`. With a `match` (matched engine), the matcher decides on/off the route
    /// and the step; everything the ring shows is worked out as in the original.
    mutating func processOfflineStepByStep(_ loc: NavLocation, _ match: NavMatch? = nil) {
        let n = steps.count
        guard n >= 2 else { offThePath = true; return }
        if currentStepIndex >= n - 2 { currentStepIndex = n - 2 }
        guard isNavigating else { offThePath = true; return }
        if let match { syncStep(match) }

        var cur = steps[currentStepIndex]
        var next = steps[currentStepIndex + 1]
        var cpl = ClosestPathLocation(loc, cur.path)
        let dist = turnStarted ? next.entrance.distance(to: loc) : cpl.distanceRemaining
        if let match {
            if match.status == .off { offThePath = true }
        } else {
            checkForUserReroute(cur, next, loc)
        }

        if offThePath {
            display.isStepAnimationNow = true
            executeGPXCompassMode(loc, cur, &next, match)
            if offlineStatus != .onPath { return }
        } else {
            hasReachedOrigin = true
            offlineStatus = .onPath
            offPathDestination = NavLocation(999, 999)
            guard processIncompleteStep(dist, next, loc, match) else { return }
            processStepComplete(next)
        }

        // Refresh after a completed step or a rejoin.
        cur = steps[currentStepIndex]
        if currentStepIndex < n - 1 {
            next = steps[currentStepIndex + 1]
            cpl = ClosestPathLocation(loc, cur.path)
            _ = processIncompleteStep(distanceToManeuver(next, loc, cpl), next, loc, match)
        }
        if match == nil, currentStepIndex >= n - 1 {           // inlined onNavigationCompleted()
            isComplete = true
            display.typesToRemove.append(.angle)
            display.currentType = .none
            sound = .destination
        }
        updateDeviceInstruction(cur, next)
    }

    /// `processIncompleteStep` → true when the manoeuvre `step` is done. With a confident `match`, the
    /// official completion only counts once the rider has reached the manoeuvre along the route: the
    /// original completes a started turn on being 20 m from it in any direction.
    mutating func processIncompleteStep(_ dist: Double, _ step: NavStep, _ loc: NavLocation,
                                        _ match: NavMatch? = nil) -> Bool {
        let done = processIncompleteStepOfficial(dist, step, loc)
        if done, let match, match.confident, let stepAlong, currentStepIndex + 1 < stepAlong.count,
           match.along < stepAlong[currentStepIndex + 1] - Self.completionGate {
            return false
        }
        return done
    }

    /// The original `processIncompleteStep`.
    mutating func processIncompleteStepOfficial(_ dist: Double, _ step: NavStep, _ loc: NavLocation) -> Bool {
        let wasAnimating = display.isStepAnimationNow
        display.isStepAnimationNow = dist < (step.type == NavStepType.destination ? 105 : 95) || turnStarted
        if wasAnimating && !display.isStepAnimationNow
            && display.currentType != .pointer && display.currentType != .none {
            display.typesToRemove.append(.angle)
        }
        if display.isStepAnimationNow && !stepAnimationStarted {
            sound = .progress
            stepAnimationStarted = true
            display.incrementCurrentStep = true
        }

        if step.type == NavStepType.destination {
            let p = Self.stepProgress(dist, step.type)
            display.currentType = .destination
            var t = NavTurn()
            t.turnProgress = p
            t.stepType = NavStepType.destination
            display.thisTurn = t
            display.distanceToThisManeuver = NavMath.trunc(max(dist - 50, 0))
            display.progress = p
            display.description = step.instructionText
            display.thisStreetName = step.streetName
            return false
        }

        let p = Self.stepProgress(dist, step.type)
        if p >= 100 && !turnStarted { sound = .turnNow; turnStarted = true }

        if step.isRoundabout {
            display.progress = p
            display.currentType = turnStarted ? .enteredRoundabout : .enteringRoundabout
            display.distanceToThisManeuver = NavMath.trunc(max(dist - 25, 0))
            display.distanceToNextManeuver = NavMath.trunc(step.roundaboutExitDistance)
            display.description = step.instructionText
            display.thisStreetName = step.streetName
            display.roundaboutExitStreetName = step.roundaboutExitStreetName
            return Self.roundaboutComplete(step.exit, step.headingAfter, turnStarted, loc)
        }

        let n = steps.count
        let thisCaution = currentStepIndex < n - 1 && steps[currentStepIndex + 1].mode == 1
        display.thisTurn.turnProgress = p
        display.distanceToThisManeuver = NavMath.trunc(max(dist - 25, 0))
        angleTurnProgressData(loc)
        let nextCaution = currentStepIndex + 2 < n && steps[currentStepIndex + 2].mode == 1
        if !nextTurnAnimationStarted && display.nextTurn.turnProgress >= 1 {
            nextTurnAnimationStarted = true
            sound = .progress
        }
        display.currentType = .angle
        display.thisTurn.mode = thisCaution ? 1 : 0
        display.nextTurn.mode = nextCaution ? 1 : 0
        display.description = step.instructionText
        display.thisStreetName = step.streetName
        // `isStepComplete` runs on a fresh copy of the step, so it is always false here.
        return Self.turnComplete(p < 100 && turnStarted, turnStarted, bearing.current,
                                 step.headingAfter, step.entrance, loc)
    }

    /// `processStepComplete`.
    mutating func processStepComplete(_ step: NavStep) {
        let n = steps.count
        let quick = currentStepIndex + 2 < n && Self.quickTurnDisplayed(step, steps[currentStepIndex + 2])
        if !quick && step.type != NavStepType.destination {
            display.typesToRemove.append(.angle)
            display.currentType = .none
        }
        currentStepIndex += 1
        if !nextTurnAnimationStarted { stepAnimationStarted = false }
        turnStarted = false
        nextTurnAnimationStarted = false
        bearing.clearCurrent()
        if currentStepIndex + 1 < n { display.incrementCurrentStep = true }
    }

    /// `getDistanceToManeuver`.
    func distanceToManeuver(_ step: NavStep, _ loc: NavLocation, _ cpl: ClosestPathLocation) -> Double {
        if step.isRoundabout && step.type <= NavStepType.roundaboutCounterClockwise {
            return turnStarted ? step.exit.distance(to: loc) : cpl.distanceRemaining
        }
        return turnStarted ? step.entrance.distance(to: loc) : cpl.distanceRemaining
    }

    /// `updateDeviceInstruction`.
    mutating func updateDeviceInstruction(_ cur: NavStep, _ next: NavStep) {
        if display.thisTurn.stepType != NavStepType.depart || display.isStepAnimationNow {
            display.deviceInstruction = display.thisStreetName.isEmpty ? display.description : display.thisStreetName
        } else {
            display.description = cur.instructionText
            display.thisStreetName = cur.streetName
            display.deviceInstruction = next.streetName.isEmpty ? next.instructionText : next.streetName
        }
        if display.isStepAnimationNow {
            display.thisTurn.mode = next.mode; display.thisTurn.stepType = next.type
        } else {
            display.thisTurn.mode = cur.mode; display.thisTurn.stepType = cur.type
            display.nextTurn.mode = next.mode; display.nextTurn.stepType = next.type
        }
    }

    // MARK: - Step sync (matched engine, docs/MAP_MATCHING_SPEC.md §6.2)

    /// Bring the step in line with where the matcher places the rider, at the start of a fix. The next
    /// manoeuvre completes the official way (with its animation) unless the rider is well past it; any
    /// other jump waits for a few confident fixes, and backwards for the rider to be clearly behind.
    mutating func syncStep(_ match: NavMatch) {
        guard let stepAlong, !match.frozen else { pendingStep = nil; return }
        let usable = offThePath
            ? hasReachedOrigin && match.unambiguous && match.distance <= Self.offRouteSyncDistance
            : match.confident
        guard usable else { pendingStep = nil; return }
        let n = steps.count
        var k = 0
        for i in 0..<n where stepAlong[i] <= match.along { k = i }
        k = min(k, n - 2)
        let cur = currentStepIndex
        if k == cur { pendingStep = nil; return }
        if offThePath {                             // so the arcs back onto the route aim ahead
            pendingStep = nil
            if k < cur && match.along >= stepAlong[cur] - Self.behindMargin { return }   // noise at a corner
            jumpToStep(k)
            return
        }
        if k == cur + 1 {
            pendingStep = nil
            if match.along - stepAlong[k] >= Self.forcedCompletionPast { processStepComplete(steps[k]) }
            return
        }
        if k < cur && match.along >= stepAlong[cur] - Self.behindMargin { pendingStep = nil; return }
        if pendingStep == k { pendingCount += 1 } else { pendingStep = k; pendingCount = 1 }
        if pendingCount >= Self.jumpFixes {
            pendingStep = nil
            jumpToStep(k)
        }
    }

    /// Move to step `k` with no animation of the steps in between: the turn state starts over, and an
    /// arc on the ring is cleared once.
    mutating func jumpToStep(_ k: Int) {
        currentStepIndex = k
        turnStarted = false
        stepAnimationStarted = false
        nextTurnAnimationStarted = false
        display.thisTurn = NavTurn()
        display.nextTurn = NavTurn()
        bearing.clearCurrent()
        if display.currentType == .angle || display.currentType == .destination {
            if !display.typesToRemove.contains(.angle) { display.typesToRemove.append(.angle) }
            display.currentType = .none
            display.isStepAnimationNow = false
        }
    }

    // MARK: - Off the path

    /// `executeGPXCompassMode`: rejoin (< 15 m), turning back onto the path (< 95 m and heading
    /// towards it), or the pointer to the nearest point of the route.
    ///
    /// With a `match` (matched engine): the target is the matcher's, the rejoin is the matcher's `on`
    /// (through the same branch, which clears the pointer and plays "back on route"), the step never
    /// moves here, while the matcher waits to rejoin the ring keeps what it shows, and the rider's
    /// direction falls back on the matcher's when `NavBearing` has none (under ~12.6 km/h).
    mutating func executeGPXCompassMode(_ loc: NavLocation, _ cur: NavStep, _ next: inout NavStep,
                                        _ match: NavMatch? = nil) {
        if match?.status == .rejoining { return }
        let target = match?.target ?? closestLocationOnNearbyPath(loc, cur, next)
        // `closestLocationOnNearbyPath` moves to the next step when its path is nearer: the manoeuvre
        // ahead is then that step's. Kept stale, the arcs aimed at the vertex just passed and the
        // "< 5 m from its entrance" rule below moved the step a second time, skipping a stretch.
        if currentStepIndex + 1 < steps.count { next = steps[currentStepIndex + 1] }
        guard target.exists else { return }
        let d = loc.distance(to: target)
        display.distanceToThisManeuver = NavMath.trunc(d.rounded())
        let brg = Int(loc.bearing(to: target))
        let crow = bearing.crowFlies != NavBearing.unknown ? bearing.crowFlies : (match?.travel ?? NavBearing.unknown)
        let headingToPath = crow != NavBearing.unknown && NavMath.smallerGap(crow, brg) < 40

        if match.map({ $0.status == .on }) ?? (d < 15) {
            if display.currentType == .pointer { display.typesToRemove.append(.pointer) }
            if display.currentType != .none { sound = .returnToPath }
            offThePath = false
            hasReachedOrigin = true
            offPathDestination = .none
            lastOffPathDistance = 0
            offlineStatus = .onPath
            display.thisTurn.stepType = NavStepType.standard
            if !nextTurnAnimationStarted { display.typesToRemove.append(.angle) }
            if headingToPath { bearing.clearCurrent() }
            stepAnimationStarted = false
            display.currentType = .none
        } else if d < 95 && headingToPath {
            if display.currentType == .pointer { display.typesToRemove.append(.pointer) }
            display.thisTurn = NavTurn()
            display.nextTurn = NavTurn()
            display.nextTurn.stepType = NavStepType.standard
            display.thisTurn.turnProgress = Self.stepProgressWithDistance(d)
            if match == nil && target.distance(to: next.entrance) < 5 {
                currentStepIndex += 1
                if currentStepIndex < steps.count - 1 { next = steps[currentStepIndex + 1] }
            }
            display.thisTurn.mode = 0
            display.currentType = .angle
            display.nextTurn.mode = 0
            angleTurnProgressDataWithoutFirstStep(next, loc, target)
            if !stepAnimationStarted { stepAnimationStarted = true; sound = .progress }
            if display.nextTurn.turnProgress >= 1 && !nextTurnAnimationStarted {
                nextTurnAnimationStarted = true
                sound = .progress
            }
            lastOffPathDistance = d
            offlineStatus = .turningOnPath
            turningOnPathAngle = display.thisTurn.relativeTurnAngle
            display.thisStreetName = NavStepFactory.description(forAngle: display.thisTurn.relativeTurnAngle)
            display.deviceInstruction = display.thisStreetName
            display.description = display.deviceInstruction
            offPathDestination = target
        } else {
            if crow != NavBearing.unknown {
                turnStarted = false
                display.progress = Self.returnToPathProgress(loc, target, Float(lastOffPathDistance))
                display.bearing = brg - crow
                offlineStatus = .offPath
            } else if match != nil {
                // Addition (matched engine): off the route is the matcher's call, direction or not.
                // The original only says so once it has one, so a rider who never went faster than
                // ~12.6 km/h got no warning at all; the director shows "Ride to calibrate" meanwhile.
                turnStarted = false
                offlineStatus = .offPath
            }
            offPathDestination = target
            lastOffPathDistance = d
            display.currentType = .pointer
            if hasReachedOrigin {
                display.description = "nav.inject.follow.heading.route"
                display.deviceInstruction = "nav.inject.follow.heading.route.device"
            } else {
                display.description = "nav.inject.follow.heading.route.starts"
                display.deviceInstruction = "nav.inject.follow.heading.route.starts.device"
            }
        }
        display.distanceToThisManeuver = NavMath.trunc(lastOffPathDistance)
    }

    /// `determineClosestLocationOnNearbyPath` (5 args): nearest point on this step's or the next
    /// step's path (moving on a step if the next is nearer); before the rider has ever been on the
    /// route, the start of the current step.
    mutating func closestLocationOnNearbyPath(_ loc: NavLocation, _ cur: NavStep, _ next: NavStep) -> NavLocation {
        guard loc.exists else { return .none }
        if hasReachedOrigin {
            let onCur = ClosestPathLocation(loc, cur.path).location
            let onNext = ClosestPathLocation(loc, next.path).location
            let dCur = loc.distance(to: onCur), dNext = loc.distance(to: onNext)
            if dCur > dNext && next.type != NavStepType.destination {
                lastOffPathDistance = dNext
                currentStepIndex += 1
                return onNext
            }
            return onCur
        }
        guard currentStepIndex < steps.count, let first = steps[currentStepIndex].path.first else { return .none }
        return first
    }

    /// `determineClosestLocationOnNearbyPath` (1 arg).
    mutating func closestLocationOnNearbyPath(_ loc: NavLocation) -> NavLocation {
        guard currentStepIndex < steps.count - 1 else { return .none }
        return closestLocationOnNearbyPath(loc, steps[currentStepIndex], steps[currentStepIndex + 1])
    }

    // MARK: - SHRerouteSystem

    /// `checkForUserReroute`: off path when more than accuracy + 20 m from the step's path (at once
    /// beyond 50 m, else on the 2nd fix in a row), or riding > 40° off the path's direction.
    mutating func checkForUserReroute(_ cur: NavStep, _ next: NavStep, _ loc: NavLocation) {
        let dCur = cur.distanceFromPath(loc)
        let tolerance = Double(loc.accuracy) + 20
        let dNext = next.distanceFromPath(loc)
        if dCur > tolerance && !(next.isRoundabout && turnStarted) {
            rerouteCheck(nearPath: dCur <= 50, loc)
            return
        }
        if dNext > tolerance && turnStarted && next.isRoundabout {
            rerouteCheck(nearPath: dNext <= 50, loc)
            return
        }
        ticksAwayFromPath = 0
        if Self.orientationReroute(turnStarted, bearing.current, cur.path, loc) {
            reroutePath(loc)
            return
        }
        if bearing.current != NavBearing.unknown {
            consecutiveRerouteCount = 0
            lastRerouteLocation = .none
            lastRerouteTime = -999
        }
    }

    mutating func rerouteCheck(nearPath: Bool, _ loc: NavLocation) {
        if nearPath {
            let old = ticksAwayFromPath
            ticksAwayFromPath += 1
            if old < 1 { return }
        }
        reroutePath(loc)
    }

    /// `reroutePath` (the back-off never applies in GPX mode: the count only grows on online reroutes).
    mutating func reroutePath(_ loc: NavLocation) {
        if consecutiveRerouteCount < 1 { offThePath = true; return }
        if lastRerouteTime != -999 {
            let wait = min(Float(consecutiveRerouteCount) * 10, 20)
            if wait > Float(now() - lastRerouteTime) { return }
        }
        if lastRerouteLocation.exists {
            let minMove = min(Double(consecutiveRerouteCount) * 25, 50)
            if loc.distance(to: lastRerouteLocation) < minMove { return }
        }
        offThePath = true
    }

    /// `checkForOrientationReroute`.
    static func orientationReroute(_ turnStarted: Bool, _ rider: Int, _ path: [NavLocation],
                                   _ loc: NavLocation) -> Bool {
        if rider == NavBearing.unknown || turnStarted { return false }
        let c = ClosestPathLocation(loc, path)
        let n = path.count
        if n < 2 { return false }
        let idx = c.index
        let seg: Float
        if idx == 0 {
            seg = Float(path[0].bearing(to: path[1]))
        } else if idx >= n - 1 {
            seg = Float(path[n - 2].bearing(to: path[n - 1]))
        } else {
            let toCur = Int(Float(c.location.bearing(to: path[idx])))
            let toNext = Int(Float(c.location.bearing(to: path[idx + 1])))
            let toPrev = Int(Float(c.location.bearing(to: path[idx - 1])))
            if NavMath.smallerGap(toCur, toPrev) >= 161 {
                seg = Float(path[idx - 1].bearing(to: path[idx]))
            } else if NavMath.smallerGap(toCur, toNext) >= 161 {
                seg = Float(path[idx].bearing(to: path[idx + 1]))
            } else {
                seg = Float(rider)
            }
        }
        return NavMath.smallerGap(rider, Int(seg)) > 40
    }

    // MARK: - Display data

    /// `checkForAngleTurnProgressData`: this turn's angle and, when the turn after it is close, the
    /// second arc.
    mutating func angleTurnProgressData(_ loc: NavLocation) {
        let idx = currentStepIndex
        let cur = steps[idx], next = steps[idx + 1]
        var nn: NavStep?
        if idx < steps.count - 2 {
            let s = steps[idx + 2]
            nn = s
            if s.type == NavStepType.destination || s.isRoundabout {
                display.nextTurn.turnProgress = 0
                display.distanceToNextManeuver = 0
            } else {
                let total = next.distanceToStepEnd(loc) + cur.distanceToStepEnd(loc)
                display.nextTurn.turnProgress = Self.stepProgress(total, s.type)
                display.distanceToNextManeuver = NavMath.trunc(max(total - 25, 0))
            }
        } else {
            display.nextTurn.turnProgress = 0
        }
        display.thisTurn.relativeTurnAngle = next.angles.first ?? 0
        display.thisTurn.relativeToNorthAngle = next.headingAfter
        if let s = nn, !s.isRoundabout, s.type != NavStepType.destination {
            display.nextTurn.relativeTurnAngle = s.angles.first ?? 0
            display.nextTurn.relativeToPreviousTurnAngle = (next.angles.first ?? 0) + (s.angles.first ?? 0)
            display.nextTurn.relativeToNorthAngle = s.headingAfter
        } else {
            display.nextTurn.relativeTurnAngle = 0
            display.nextTurn.relativeToPreviousTurnAngle = 0
            display.nextTurn.relativeToNorthAngle = 0
        }
    }

    /// `checkForAngleTurnProgressDataWithoutFirstStep`: turning back onto the route — this arc
    /// points at the rejoin point, the next arc is the route's next turn.
    mutating func angleTurnProgressDataWithoutFirstStep(_ step: NavStep, _ a: NavLocation, _ b: NavLocation) {
        let b1 = a.bearing(to: b)
        let b2 = b.bearing(to: step.entrance)
        display.thisTurn.relativeTurnAngle = NavMath.normalized(NavMath.trunc(b2 - b1))
        display.thisTurn.relativeToNorthAngle = NavMath.normalized(NavMath.trunc(b2))
        if step.type == NavStepType.destination {
            display.nextTurn.relativeTurnAngle = 0
            display.nextTurn.relativeToPreviousTurnAngle = 0
            display.nextTurn.relativeToNorthAngle = 0
            display.nextTurn.turnProgress = 0
            return
        }
        let total = a.distance(to: b) + step.entrance.distance(to: a)
        let angle = step.angles.first ?? 0
        display.nextTurn.turnProgress = Self.stepProgress(total, step.type)
        display.nextTurn.relativeTurnAngle = NavMath.normalized(angle)
        display.nextTurn.relativeToPreviousTurnAngle = NavMath.normalized(angle + display.thisTurn.relativeTurnAngle)
        display.nextTurn.relativeToNorthAngle = step.headingAfter
    }

    // MARK: - Arrival

    /// `hasArrivedAtDestination`: within ~50.5 m (straight line) of the last point — except early in
    /// the route (step index ≤ n/2 − 1 and, for 6+ steps, < n − 5), so a loop doesn't end at its start.
    public func hasArrived(at loc: NavLocation) -> Bool {
        let n = steps.count
        guard n > 0 else { return false }
        if currentStepIndex <= n / 2 - 1 && n >= 6 && currentStepIndex < n - 5 { return false }
        let d = steps[n - 1].entrance.distance(to: loc)
        return Self.stepProgress(d, NavStepType.destination) > 99
    }

    // MARK: - Helpers

    /// `determineClosestStep`: nearest step start (float precision, first minimum wins).
    static func closestStep(_ loc: NavLocation, _ steps: [NavStep]) -> Int {
        guard let first = steps.first?.path.first else { return 0 }
        var best = Float(loc.distance(to: first))
        var idx = 0
        for (i, s) in steps.enumerated() {
            guard let p = s.path.first else { continue }
            let d = Float(loc.distance(to: p))
            if d < best { best = d; idx = i }
        }
        return idx
    }

    /// `getStepProgress`: 100 within 20 m (destination 50 m), 0 beyond 95 m (105 m).
    static func stepProgress(_ dist: Double, _ type: Int) -> Int {
        let start = type == NavStepType.destination ? 50.0 : 20.0
        let end = type == NavStepType.destination ? 105.0 : 95.0
        let p = NavMath.trunc(max((dist - start) * 100 / (end - start), 0))
        return NavMath.trunc(max(100 - Double(p), 0))
    }

    /// `getStepProgressWithDistance`.
    static func stepProgressWithDistance(_ d: Double) -> Int {
        NavMath.trunc(max(100 - max((d - 20) * 100 / 75, 0), 0))
    }

    /// `getReturnToPathProgress` (relative to the previous off-path distance).
    static func returnToPathProgress(_ a: NavLocation, _ b: NavLocation, _ total: Float) -> Int {
        let d = Float(a.distance(to: b))
        return NavMath.clampTrunc((total - d + 95) / total * 100, 0, 100)
    }

    /// `checkForQuickTurnDisplayed`.
    static func quickTurnDisplayed(_ step: NavStep, _ after: NavStep) -> Bool {
        let fd = step.firstDistance
        if fd < 0 || step.isRoundabout || after.isRoundabout || !(fd < 95) { return false }
        return after.type != NavStepType.destination
    }

    /// `validateTurnCompleteStateFromBearing`.
    static func turnComplete(_ force: Bool, _ turnStarted: Bool, _ rider: Int, _ headingAfter: Int,
                             _ entrance: NavLocation, _ user: NavLocation) -> Bool {
        if force { return true }
        if rider == NavBearing.unknown || !turnStarted { return false }
        let h = headingAfter > 180 ? headingAfter - 360 : headingAfter
        if NavMath.smallerGap(rider, h) > 39 { return false }
        return NavMath.smallerGap(rider, Int(entrance.bearing(to: user))) < 40
    }

    /// `validateRoundaboutComplete`.
    static func roundaboutComplete(_ exit: NavLocation, _ headingAfter: Int, _ turnStarted: Bool,
                                   _ user: NavLocation) -> Bool {
        var b = Int(exit.bearing(to: user))
        if b < 0 { b += 360 }
        return NavMath.smallerGap(b, headingAfter) < 40 && turnStarted
    }
}
