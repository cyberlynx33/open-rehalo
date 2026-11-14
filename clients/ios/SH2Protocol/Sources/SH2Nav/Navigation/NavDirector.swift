import Foundation

/// One BLE command for the ring, in order.
public struct NavCommand: Equatable, Sendable {
    public let data: Data
    public let label: String
    /// Send this long after the previous commands (the arrival's `navOff`, 10 s later).
    public var delay: TimeInterval = 0

    public init(data: Data, label: String, delay: TimeInterval = 0) {
        self.data = data; self.label = label; self.delay = delay
    }
}

/// The Java side of the official app's GPX navigation (`SHDirectionService` +
/// `NavigationCommandsController`): on every GPS fix it runs `NavGuidance` and turns the result into
/// ring commands. No dedup or rate limit, as in the original (one fix ≈ 1 s).
///
/// Lifecycle: `start` (intro), `update` per fix, `stop` (user ends the ride). Arrival is detected in
/// `update` (`arrived` in the result) and sends the arrival sequence itself.
public struct NavDirector: Sendable {
    public struct Settings: Sendable {
        public var metric = true
        /// `isNavigationSoundOn` / `navigationVolume` (official defaults: on, 50).
        public var soundOn = true
        public var volume: UInt8 = 50
        /// The rider's carousel cards; the navigation bit is added while navigating.
        public var carouselCards: UInt16 = NavDirector.defaultCards
        public init(metric: Bool = true, soundOn: Bool = true, volume: UInt8 = 50,
                    carouselCards: UInt16 = NavDirector.defaultCards) {
            self.metric = metric; self.soundOn = soundOn; self.volume = volume
            self.carouselCards = carouselCards
        }
    }

    public struct Result: Sendable {
        public var commands: [NavCommand] = []
        /// The rider reached the destination on this fix (the ride is over).
        public var arrived = false
    }

    /// Official carousel cards: distance, time, speed, calories, clock, average speed, battery
    /// (`MetricsCarouselMask` defaults).
    public static let defaultCards: UInt16 = 0x02fc
    /// Carousel mask while navigating: the rider's cards + the navigation bit.
    var carouselMask: UInt16 { settings.carouselCards | Commands.CarouselCard.navigation.bit }
    /// The ring's Navigation card in its carousel.
    public static let navigationCard: UInt8 = 0

    public let title: String
    public let steps: [NavStep]
    public var settings: Settings
    /// The ring's carousel is on the Navigation card (it reports this itself, BLE notification 5,2).
    public var carouselOnNavigation = false
    public private(set) var guidance: NavGuidance?
    public private(set) var completed = false
    /// The intro couldn't be shown at start (no ring): show it when the ring connects.
    public private(set) var introPending = false
    /// `currentLocation`: the previous fix (Java updates it after processing).
    var currentLocation: NavLocation?
    /// Addition: OLED text per turn (step index → text), from a routed destination's own
    /// instructions (street names) instead of "Turn left/right". Empty for a GPX.
    public let turnTexts: [Int: String]
    /// Addition: the steps came from a routing service, not from the GPX turn detector.
    public let routed: Bool
    /// Join the route at its nearest point instead of its start (`NavGuidance.joinNearestStretch`,
    /// in place of the official "start from the nearest step"). Applied at the first fix.
    public var startAtNearestStep = false
    /// What the last fix asked for and `update` has already consumed: for the ride trace.
    public private(set) var lastSound = NavSoundStatus.none
    public private(set) var lastRemoved: [NavAnimation] = []
    /// Addition (matched engine): where each step's manoeuvre is along the route
    /// (docs/MAP_MATCHING_SPEC.md §6.1).
    public private(set) var stepAlong: [Double]?
    /// Addition: the ring shows the wrong-way U-turn on top of the guidance (§9.1).
    public private(set) var wrongWayShown = false
    /// The OLED text of the wrong-way U-turn (English, like the official texts).
    public static let wrongWayText = "Turn around"

    /// `points` = the GPX selection of `NavStepFactory.points(waypoints:trackPoints:)`.
    /// `title` = the destination's name (intro, arrival, destination arcs).
    /// `instructions` = where each instruction of a routed destination starts + its text; a turn
    /// takes the text of the nearest one within `instructionRadius` metres of its vertex.
    public init(points: [NavLocation], title: String, settings: Settings = Settings(),
                instructions: [(location: NavLocation, text: String)] = []) {
        steps = NavStepFactory.steps(from: points)
        self.title = title.isEmpty ? "Your destination" : title
        self.settings = settings
        turnTexts = Self.turnTexts(steps, instructions)
        routed = false
    }

    /// Addition: a routed destination on its own steps, without the GPX turn detector.
    public init(routed routedSteps: [RoutedStep], title: String, settings: Settings = Settings()) {
        let built = NavStepFactory.steps(routed: routedSteps)
        steps = built.steps
        self.title = title.isEmpty ? "Your destination" : title
        self.settings = settings
        turnTexts = built.texts
        routed = true
    }

    static let instructionRadius = 30.0

    /// Step index → the text of the nearest instruction to its vertex (turns only, not the first
    /// stretch or the destination).
    static func turnTexts(_ steps: [NavStep], _ instructions: [(location: NavLocation, text: String)]) -> [Int: String] {
        guard steps.count > 2, !instructions.isEmpty else { return [:] }
        var texts: [Int: String] = [:]
        for i in 1..<(steps.count - 1) {
            let vertex = steps[i].entrance
            let nearest = instructions
                .map { (d: $0.location.distance(to: vertex), text: $0.text) }
                .filter { $0.d <= instructionRadius && !$0.text.isEmpty }
                .min { $0.d < $1.d }
            if let nearest { texts[i] = nearest.text }
        }
        return texts
    }

    // MARK: - Lifecycle

    /// `guideToDestination` → `IntroAnimationsController.showIntroAnimation`: OLED intro with the
    /// title, then the carousel jumps to the Navigation card. Without a ring it waits (`introPending`).
    public mutating func start(ringConnected: Bool) -> [NavCommand] {
        guard ringConnected else { introPending = true; return [] }
        introPending = false
        return intro()
    }

    /// The ring connected while `introPending`: the original waits for movement + 3 s, then retries.
    public mutating func ringConnected() -> [NavCommand] {
        guard introPending else { return [] }
        introPending = false
        var cmds = intro()
        if !cmds.isEmpty { cmds[0].delay = 3 }
        return cmds
    }

    func intro() -> [NavCommand] {
        [NavCommand(data: Commands.turnByTurnIntro(title: title), label: "turnByTurnIntro"),
         NavCommand(data: Commands.carouselPosition(Self.navigationCard, mask: carouselMask),
                    label: "carouselPosition")]
    }

    /// The user ended the ride (`stopSelfAndCleanup` → `stopNavCommandOnSmartHalo`).
    public mutating func stop() -> [NavCommand] {
        guidance?.isNavigating = false
        return stopNavCommand()
    }

    // MARK: - Per fix

    /// `SHDirectionService.onNewLocation` for a GPX ride. `fix.accuracy` = rounded horizontal
    /// accuracy in metres; `speed` the fix's ground speed (m/s, nil or negative = unknown), which
    /// times the notices; `routeShare` how much of the route the rider has covered (0…1), for the
    /// arrival rule (nil: the original's step-count guard).
    public mutating func update(_ fix: NavLocation, speed: Double? = nil, routeShare: Double? = nil) -> Result {
        update(fix, match: nil, speed: speed, routeShare: routeShare)
    }

    /// Addition (matched engine): use the matcher for where the rider is. Call before the first fix.
    public mutating func enableMatching(stepAlong: [Double]) {
        self.stepAlong = stepAlong
        guidance?.enableMatching(stepAlong: stepAlong)
    }

    /// One fix. With a `match` (matched engine, docs/MAP_MATCHING_SPEC.md §6–§9) the matcher decides
    /// on/off the route, the step and arrival, and `wrongWay` puts the U-turn on the ring; without one,
    /// exactly the official flow.
    public mutating func update(_ fix: NavLocation, match: NavMatch?, wrongWay: Bool = false,
                                speed: Double? = nil, routeShare: Double? = nil) -> Result {
        var result = Result()
        guard !completed else { return result }
        if guidance == nil {
            // The original builds the guidance from the location at GPX load; here, the first fix.
            var g = NavGuidance(start: fix, steps: steps)
            g.isNavigating = true
            if startAtNearestStep { g.joinNearestStretch(fix) }
            if match != nil, let stepAlong { g.enableMatching(stepAlong: stepAlong) }
            guidance = g
            currentLocation = fix
        }
        guard var g = guidance else { return result }

        if let match { g.update(fix, match: match, speed: speed) } else { g.update(fix, speed: speed) }
        // The Navigation card that `stopNavCommand` refreshes is read from the guidance after this fix,
        // as the original reads the library's display status after `updateState`: the next turn, not
        // the one just completed.
        guidance = g
        let ds = g.display
        let sound = g.sound
        lastSound = sound
        lastRemoved = ds.typesToRemove
        for type in ds.typesToRemove {
            result.commands += type == .pointer ? [pointerOff] : stopNavCommand()
        }
        // Fix: back on the route with nothing to show yet, `navPointerOff` alone leaves
        // "Return to route" on the OLED: the firmware only clears it if no arc ever had progress
        // (`silencePointerNavigation`, RideTask.c:494), and that progress is never reset.
        if ds.typesToRemove.contains(.pointer), !ds.typesToRemove.contains(.angle),
           g.offlineStatus == .onPath, !ds.isStepAnimationNow {
            result.commands.append(NavCommand(data: Commands.navOff(), label: "navOff"))
        }
        g.clearTypesToRemove()
        guidance = g

        // processOfflineTurnByTurnResults
        if g.offlineStatus == .offPath {
            result.commands += gpsCompassResults(ds, g)
        } else {
            result.commands += stepByStepResults(ds, sound, g)
            if match == nil, g.isComplete { result.commands += navigationCompleted(); result.arrived = true }
        }
        guidance?.sound = .none

        if let match {
            if !completed, match.arrived {
                result.commands += navigationCompleted()
                result.arrived = true
            }
            result.commands = wrongWayLayer(result.commands, wrongWay: wrongWay && !completed)
        } else if !completed, g.hasReachedOrigin, g.hasArrived(at: fix, routeShare: routeShare) {
            result.commands += navigationCompleted()
            result.arrived = true
        }
        currentLocation = fix
        return result
    }

    /// Addition: the wrong-way U-turn, drawn over whatever the guidance shows (§9.1). On entry the ring
    /// is cleared, the glyph drawn and a sound played; while it lasts the guidance's commands are
    /// dropped and the glyph re-sent each fix; on exit `navOff`, and the guidance takes over again.
    mutating func wrongWayLayer(_ commands: [NavCommand], wrongWay: Bool) -> [NavCommand] {
        if wrongWay {
            let glyph = NavCommand(data: Commands.nav(stepType: UInt8(NavStepType.uTurn), progress: 100, distance: 0,
                                                      text: Self.wrongWayText, metric: settings.metric,
                                                      colour: Commands.NavColour.warning),
                                   label: "nav")
            if wrongWayShown { return [glyph] }
            wrongWayShown = true
            var cmds = stopNavCommand() + [glyph]
            if settings.soundOn {
                cmds.append(NavCommand(data: Commands.soundPlay(volume: settings.volume, track: Commands.NavSound.wrongWay),
                                       label: "sound"))
            }
            return cmds
        }
        guard wrongWayShown else { return commands }
        wrongWayShown = false
        return [NavCommand(data: Commands.navOff(), label: "navOff")] + commands
    }

    /// Addition: what clears the ring (the route is about to change under it).
    public func clearRing() -> [NavCommand] { stopNavCommand() }

    /// Addition: a director for the same ride on another route (an inverted one): the same title,
    /// settings and carousel state, no intro to show.
    public func continuing(on points: [NavLocation]) -> NavDirector {
        var d = NavDirector(points: points, title: title, settings: settings)
        d.carouselOnNavigation = carouselOnNavigation
        d.currentLocation = currentLocation
        return d
    }

    /// Addition (matched engine): the ride carries on `along` metres into this director's route, the
    /// rider at `fix` (an inverted route, §9.3). The guidance starts there, on the route: built at the
    /// first fix instead, it would start at step 0 and the step sync would take a few fixes to catch up.
    public mutating func placeOnRoute(at along: Double, from fix: NavLocation) {
        guard guidance == nil, let stepAlong else { return }
        var g = NavGuidance(start: fix, steps: steps)
        g.isNavigating = true
        g.enableMatching(stepAlong: stepAlong)
        g.placeOnRoute(at: along, from: fix)
        guidance = g
        currentLocation = fix
    }

    /// The ring switched to its Navigation card: answer with the card's content.
    public func carouselCard() -> NavCommand {
        if wrongWayShown {
            return NavCommand(data: Commands.carouselNavigationCard(mask: carouselMask, distance: 0, angle: 180,
                                                                    text: Self.wrongWayText, metric: settings.metric),
                              label: "carousel")
        }
        guard let ds = guidance?.display else {
            return NavCommand(data: Commands.carouselNavigationCard(mask: carouselMask), label: "carousel")
        }
        var distance = ds.distanceToThisManeuver
        if ds.currentType == .enteredRoundabout { distance = 0 }
        var angle = ds.thisTurn.relativeTurnAngle
        let roundabout = ds.currentType == .enteringRoundabout || ds.currentType == .enteredRoundabout
        // The exit to take comes first in `roundaboutAngles` (`RoundaboutExits`); the original read the
        // gap between Valhalla's first and last exit, which this port never had.
        if roundabout, let exit = ds.roundaboutAngles.first { angle = exit }
        var text = ds.roundaboutExitStreetName.isEmpty ? ds.deviceInstruction : ds.roundaboutExitStreetName
        if let converted = Self.instructionText(text) { text = converted }
        if let g = guidance, let routed = turnText(g) { text = routed }
        if ds.currentType == .destination { text = title; angle = 0 }
        return NavCommand(data: Commands.carouselNavigationCard(mask: carouselMask, distance: distance,
                                                                angle: angle, text: text,
                                                                metric: settings.metric),
                          label: "carousel")
    }

    // MARK: - Java dispatch

    /// `processGPSCompassModeResults` (off the path): "ride to calibrate" until the direction of
    /// travel is known, then the orange pointer to the route. The original asks the bearings; this
    /// asks whether the pointer has an angle, which is the same thing on the official flow (the
    /// angle is set on the fix the direction appears) and also right when the angle comes from the
    /// matcher's direction, or hasn't been computed yet on a fix the matcher held or kept rejoining.
    func gpsCompassResults(_ ds: NavDisplayStatus, _ g: NavGuidance) -> [NavCommand] {
        let text = Self.instructionText(ds.deviceInstruction) ?? ds.deviceInstruction
        if ds.bearing == NavBearing.unknown {
            return [NavCommand(data: Commands.navPointerStandby(distance: distanceToDestination - Self.arrivalRadius, text: text,
                                                                metric: settings.metric,
                                                                colour: Commands.NavColour.progress(ds.progress)),
                               label: "navPointerStandby")]
        }
        return [NavCommand(data: Commands.navPointer(angle: ds.bearing, distance: ds.distanceToThisManeuver,
                                                     text: text, metric: settings.metric,
                                                     colour: Commands.NavColour.offPath),
                           label: "navPointer")]
    }

    /// `processStepByStepResults` (on the path / turning onto it): the command for the current
    /// animation on every fix while it runs, plus its sound.
    func stepByStepResults(_ ds: NavDisplayStatus, _ sound: NavSoundStatus, _ g: NavGuidance) -> [NavCommand] {
        guard ds.isStepAnimationNow else { return [] }
        var cmds: [NavCommand] = []
        let metric = settings.metric
        switch ds.currentType {
        case .pointer:
            cmds.append(NavCommand(data: Commands.navPointer(angle: ds.bearing, distance: distanceToDestination - Self.arrivalRadius,
                                                             text: title, metric: metric,
                                                             colour: Commands.NavColour.progress(ds.progress)),
                                   label: "navPointer"))
        case .angle:
            let colour = Self.colour(ds.thisTurn.mode)
            let text = turnText(g) ?? Self.instructionText(ds.deviceInstruction) ?? ds.deviceInstruction
            cmds.append(NavCommand(data: Commands.navAngle(
                colour: colour, angle: ds.thisTurn.relativeTurnAngle, progress: ds.thisTurn.turnProgress,
                sameTurn: g.offlineStatus != .onPath,
                nextColour: colour,                                   // sic: this turn's mode
                nextAngle: ds.nextTurn.relativeTurnAngle, nextProgress: ds.nextTurn.turnProgress,
                distance: ds.distanceToThisManeuver, nextDistance: ds.distanceToNextManeuver,
                text: text, metric: metric), label: "navAngle"))
        case .destination:
            cmds.append(NavCommand(data: Commands.nav(stepType: UInt8(NavStepType.destination), progress: ds.progress,
                                                      distance: ds.distanceToThisManeuver, text: title,
                                                      metric: metric, colour: Commands.NavColour.turn),
                                   label: "nav"))
        case .uTurn:
            cmds.append(NavCommand(data: Commands.nav(stepType: UInt8(NavStepType.uTurn), progress: ds.progress,
                                                      distance: ds.distanceToThisManeuver, text: ds.description,
                                                      metric: metric, colour: Commands.NavColour.warning),
                                   label: "nav"))
        case .enteringRoundabout, .enteredRoundabout:
            // Addition: a routed roundabout with a known exit (a GPX has none) on the ring's own glyph,
            // the exits' angles from the entry with the one to take first, blinking once the rider is
            // in it, and the exit on the OLED (`Commands.roundabout`, `roundaboutOled`).
            let step = g.steps[min(g.currentStepIndex + 1, g.steps.count - 1)]
            let exits = ds.roundaboutAngles.isEmpty ? [ds.thisTurn.relativeTurnAngle] : ds.roundaboutAngles
            let style: Commands.RoundaboutStyle = step.type == NavStepType.roundaboutClockwise ? .clockwise : .counterClockwise
            let text = turnText(g) ?? Self.instructionText(ds.deviceInstruction) ?? ds.deviceInstruction
            cmds.append(NavCommand(data: Commands.roundabout(exits: exits, exitNow: ds.currentType == .enteredRoundabout,
                                                             style: style, exitColour: Self.colour(ds.thisTurn.mode)),
                                   label: "roundabout"))
            cmds.append(NavCommand(data: Commands.roundaboutOled(distance: ds.distanceToThisManeuver, text: text,
                                                                 metric: metric),
                                   label: "roundaboutOled"))
        case .none:
            break
        }
        let track: [UInt8]? = switch sound {
        case .progress: Commands.NavSound.progress
        case .turnNow: Commands.NavSound.turnNow
        case .destination: Commands.NavSound.destination
        case .returnToPath: Commands.NavSound.info
        case .none: nil
        }
        if let track, settings.soundOn {
            cmds.append(NavCommand(data: Commands.soundPlay(volume: settings.volume, track: track), label: "sound"))
        }
        return cmds
    }

    /// The routed text for the turn being shown, on the route only (turning onto it keeps
    /// "Turn left/right").
    func turnText(_ g: NavGuidance) -> String? {
        let shown: Set<NavAnimation> = [.angle, .enteringRoundabout, .enteredRoundabout]
        guard g.offlineStatus == .onPath, shown.contains(g.display.currentType) else { return nil }
        return turnTexts[g.currentStepIndex + 1]
    }

    /// The OLED's distance to the destination runs out at the arrival radius, as the official's did
    /// at its 50 m.
    static let arrivalRadius = Int(TurnTiming.arrivalRadius)

    /// `onNavigationCompleted` + `onDestinationReached`: clear the ring, destination sound, the full
    /// green ring with the title, and `navOff` 10 s later.
    mutating func navigationCompleted() -> [NavCommand] {
        guard !completed else { return [] }
        completed = true
        guidance?.isNavigating = false
        return stopNavCommand() + Self.destinationReached(title: title, settings: settings)
    }

    /// `onDestinationReached(title)`: destination sound, the full green ring with the title, and
    /// `navOff` 10 s later.
    static func destinationReached(title: String, settings: Settings) -> [NavCommand] {
        var cmds: [NavCommand] = []
        if settings.soundOn {
            cmds.append(NavCommand(data: Commands.soundPlay(volume: settings.volume, track: Commands.NavSound.destination),
                                   label: "sound"))
        }
        cmds.append(NavCommand(data: Commands.nav(stepType: UInt8(NavStepType.destination), progress: 100, distance: 0,
                                                  text: title, metric: settings.metric, colour: Commands.NavColour.turn),
                               label: "nav"))
        cmds.append(NavCommand(data: Commands.navOff(), label: "navOff", delay: 10))
        return cmds
    }

    /// `stopNavCommandOnSmartHalo` (GPX / turn-by-turn): refresh the carousel card if it's showing,
    /// pointer off, navigation off.
    func stopNavCommand() -> [NavCommand] {
        var cmds: [NavCommand] = []
        if carouselOnNavigation { cmds.append(carouselCard()) }
        cmds.append(pointerOff)
        cmds.append(NavCommand(data: Commands.navOff(), label: "navOff"))
        return cmds
    }

    var pointerOff: NavCommand { NavCommand(data: Commands.navPointerOff(), label: "navPointerOff") }

    /// `(int) destination.distanceTo(currentLocation)`, from the previous fix.
    var distanceToDestination: Int {
        guard let g = guidance, let loc = currentLocation else { return 0 }
        return NavMath.trunc(g.destination.distance(to: loc))
    }

    // MARK: - Text and colours

    /// `DirectionHelper.convertStepInstruction` (the app only ships English): nil = not a known key,
    /// the caller shows the raw text. Two entries keep their literal `%1$s`, as in the original.
    public static func instructionText(_ key: String) -> String? {
        switch key {
        case "nav.inject.continue.instruction": "Continue down"
        case "nav.found.left": "Turn left"
        case "nav.found.right": "Turn right"
        case "nav.inject.direct.instruction": "Continue towards your destination"
        case "nav.inject.direct.arrival", "nav.inject.arrival": "You have arrived at your destination"
        case "nav.inject.departure": "Continue down the path"
        case "nav.inject.follow.heading.route.starts":
            "Follow heading on SmartHalo towards your itinerary's start for %1$s"
        case "nav.inject.follow.heading.route": "Follow heading on SmartHalo towards your itinerary for %1$s"
        case "nav.inject.follow.heading.route.starts.device": "Go to GPX start"
        case "nav.inject.follow.heading.route.device": "Return to route"
        default: nil
        }
    }

    /// Addition: a routed instruction ("Turn right onto Carrer Major", "Gira a la derecha
    /// hacia Av. Catalunya") shortened to the street for the OLED; the whole instruction when no
    /// street is recognised. "Toward X" names where the road leads, not the road: it only counts when
    /// nothing else does, and is cut off a street that carries it ("on US-101 toward San Jose").
    public static func shortInstruction(_ instruction: String) -> String {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let streets = [" onto ", " on ", " por ", " en ", " a "]
        let destinations = [" toward ", " towards ", " hacia "]
        for sep in streets + destinations {
            guard let r = text.range(of: sep, options: [.caseInsensitive, .backwards]) else { continue }
            var street = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if streets.contains(sep) {
                for d in destinations {
                    if let cut = street.range(of: d, options: .caseInsensitive) { street = String(street[..<cut.lowerBound]) }
                }
            }
            if let first = street.unicodeScalars.first,
               CharacterSet.uppercaseLetters.union(.decimalDigits).contains(first) {
                return street.hasSuffix(".") ? String(street.dropLast()) : street
            }
        }
        return text
    }

    /// `DirectionHelper.getNavColour(mode)`.
    static func colour(_ mode: Int) -> Commands.Colour {
        mode == 1 ? Commands.NavColour.caution : Commands.NavColour.turn
    }

    /// `DirectionHelper.getClockwiseAngleGap`.
    static func clockwiseGap(_ a: Int, _ b: Int) -> Int {
        var a = a
        if b > a { a += 360 }
        return 180 - (a - b)
    }
}
