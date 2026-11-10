import Foundation

/// The official app's "as the crow flies" navigation (`NavigationMode.AsTheCrowFliesGPS`): no route,
/// the ring points straight at the destination, relative to the rider's direction of travel, with
/// the distance and the destination's name on the OLED (`processGPSCompassModeResults`, mode 3 of
/// `SHGuidance::updateState`).
///
/// The rider's direction comes from successive GPS fixes (`NavBearing`, as the original). The reimplementation
/// adds one thing: `update(_:heading:)` takes an optional heading (the iPhone compass, which the app
/// passes only while the rider is slow or stopped) that wins over the GPS direction.
public struct CompassDirector: Sendable {
    public let title: String
    public let destination: NavLocation
    public var settings: NavDirector.Settings
    public private(set) var bearing = NavBearing()
    public private(set) var completed = false
    /// `initialDistance`: distance to the destination at the first fix (progress reference).
    public private(set) var initialDistance: Double?
    /// The intro couldn't be shown at start (no ring): show it when the ring connects.
    public private(set) var introPending = false
    /// `currentLocation`: the previous fix (Java updates it after processing).
    var currentLocation: NavLocation?

    public init(destination: NavLocation, title: String, settings: NavDirector.Settings = .init()) {
        self.destination = destination
        self.title = title.isEmpty ? "Your destination" : title
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Same intro as a route: title on the OLED, then the carousel's Navigation card.
    public mutating func start(ringConnected: Bool) -> [NavCommand] {
        guard ringConnected else { introPending = true; return [] }
        introPending = false
        return intro()
    }

    public mutating func ringConnected() -> [NavCommand] {
        guard introPending else { return [] }
        introPending = false
        var cmds = intro()
        if !cmds.isEmpty { cmds[0].delay = 3 }
        return cmds
    }

    func intro() -> [NavCommand] {
        let mask = settings.carouselCards | Commands.CarouselCard.navigation.bit
        return [NavCommand(data: Commands.turnByTurnIntro(title: title), label: "turnByTurnIntro"),
                NavCommand(data: Commands.carouselPosition(NavDirector.navigationCard, mask: mask),
                           label: "carouselPosition")]
    }

    /// `stopNavCommandOnSmartHalo` for AsTheCrowFliesGPS: pointer off only.
    public mutating func stop() -> [NavCommand] {
        completed = true
        return [pointerOff]
    }

    // MARK: - Per fix

    /// One GPS fix. `heading` (degrees, 0 = north), when given, is used instead of the GPS
    /// direction — the only addition.
    public mutating func update(_ fix: NavLocation, heading: Double? = nil) -> NavDirector.Result {
        var result = NavDirector.Result()
        guard !completed else { return result }
        if initialDistance == nil {
            initialDistance = max(1, destination.distance(to: fix))
            bearing.previousLocation = fix
            currentLocation = fix
        }
        bearing.update(fix)

        let p = progress(fix)
        let distance = NavMath.trunc(destination.distance(to: currentLocation ?? fix)) - 50
        let colour = Commands.NavColour.progress(p)
        let rider: Int? = heading.map { NavMath.trunc($0.rounded()) }
            ?? (bearing.crowFlies != NavBearing.unknown ? bearing.crowFlies : nil)
        if let rider {
            let angle = NavMath.trunc((fix.bearing(to: destination) - Double(rider)).rounded())
            result.commands.append(NavCommand(data: Commands.navPointer(angle: angle, distance: distance, text: title,
                                                                        metric: settings.metric, colour: colour),
                                              label: "navPointer"))
        } else {
            result.commands.append(NavCommand(data: Commands.navPointerStandby(distance: distance, text: title,
                                                                               metric: settings.metric,
                                                                               colour: colour),
                                              label: "navPointerStandby"))
        }
        currentLocation = fix

        if NavGuidance.stepProgress(destination.distance(to: fix), NavStepType.destination) > 99 {
            completed = true
            result.commands = [pointerOff] + NavDirector.destinationReached(title: title, settings: settings)
            result.arrived = true
        }
        return result
    }

    /// `getAsTheCrowFliesProgress`: 0 at the start, 100 within 50 m.
    func progress(_ fix: NavLocation) -> Int {
        guard let total = initialDistance.map(Float.init) else { return 0 }
        let d = Float(fix.distance(to: destination))
        return NavMath.clampTrunc((total - d + 50) / total * 100, 0, 100)
    }

    var pointerOff: NavCommand { NavCommand(data: Commands.navPointerOff(), label: "navPointerOff") }
}
