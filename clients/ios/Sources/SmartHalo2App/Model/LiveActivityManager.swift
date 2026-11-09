import Foundation
import Combine
import ActivityKit
import SH2Protocol

/// Drives the navigation Live Activity / Dynamic Island (UX_DESIGN §4.8) from
/// `GuidanceController.shared`. No push notifications: updates come from the app itself, which
/// keeps running in the background while navigating (background `location` mode).
///
/// - **Start** when guidance starts (the app is in the foreground then, as ActivityKit requires).
/// - **Update**, throttled to save battery: at once on a manoeuvre change, off-route enter/exit,
///   Halo connect/drop or light change; otherwise when the rider has covered ≥ 50 m AND ≥ 10 s
///   have passed since the last update.
/// - **End** on stop / arrival with a final state (average speed, distance ridden), dismissed by
///   the system after a few minutes.
///
/// Leftover activities from a previous process (crash, force quit) are ended on `activate()`.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let guidance: GuidanceController
    private let connection: HaloConnection
    private let settings: AppSettings

    private var activity: Activity<HaloNavAttributes>?
    private var activityRouteID: UUID?
    private var lastState: HaloNavAttributes.ContentState?
    private var lastPushAt = Date.distantPast
    private var lastPushRemaining: Double = 0
    private var bag = Set<AnyCancellable>()
    private var activated = false

    /// Minimum spacing between "progress only" updates.
    private let minDistanceStep: Double = 50     // metres
    private let minInterval: TimeInterval = 10   // seconds
    /// How long the final state stays on the Lock Screen after the ride ends.
    private let dismissAfter: TimeInterval = 4 * 60

    private init() {
        guidance = .shared
        connection = .shared
        settings = .shared
    }

    /// Call once at launch (`SmartHalo2App.init`).
    func activate() {
        guard !activated else { return }
        activated = true

        // A previous process may have left an activity behind: end it right away.
        for old in Activity<HaloNavAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }

        let lightChanges = connection.$controller
            .map { c -> AnyPublisher<Bool, Never> in
                c?.$lightOn.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .map { _ in () }

        // `objectWillChange` fires before the new values land: coalesce on the main queue and read
        // the guidance state afterwards.
        guidance.objectWillChange.map { _ in () }
            .merge(with: connection.$state.map { _ in () }, lightChanges)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.evaluate() }
            .store(in: &bag)
    }

    // MARK: - Light button (ToggleHaloLightIntent, runs in the app process)

    /// Toggle the front light through the shared controller; no-op without a connected Halo.
    static func toggleLightFromIntent() async {
        let connection = HaloConnection.shared
        guard connection.state == .connected, let controller = connection.controller else {
            shared.evaluate(force: true)
            return
        }
        await controller.setLight(on: !controller.lightOn)
        shared.evaluate(force: true)
    }

    // MARK: - State machine

    private func evaluate(force: Bool = false) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled || activity != nil else { return }

        if guidance.following, let route = guidance.route, let nav = guidance.navState {
            let state = contentState(for: nav)
            if let activity, activityRouteID == route.id {
                if force || shouldPush(state, remaining: nav.remaining) {
                    push(state, remaining: nav.remaining, to: activity)
                }
            } else {
                // New ride (or a different route started without stopping): replace the activity.
                if let old = activity { Task { await old.end(nil, dismissalPolicy: .immediate) } }
                start(routeID: route.id, routeName: nav.routeName, state: state, remaining: nav.remaining)
            }
        } else if let activity {
            end(activity)
        }
    }

    private func shouldPush(_ s: HaloNavAttributes.ContentState, remaining: Double) -> Bool {
        guard let last = lastState else { return true }
        if s == last { return false }
        if s.turn != last.turn || s.offRoute != last.offRoute
            || s.haloConnected != last.haloConnected || s.lightOn != last.lightOn {
            return true
        }
        return abs(lastPushRemaining - remaining) >= minDistanceStep
            && Date().timeIntervalSince(lastPushAt) >= minInterval
    }

    private func start(routeID: UUID, routeName: String,
                       state: HaloNavAttributes.ContentState, remaining: Double) {
        activity = nil
        activityRouteID = nil
        lastState = nil
        do {
            let a = try Activity<HaloNavAttributes>.request(attributes: HaloNavAttributes(routeName: routeName),
                                         content: ActivityContent(state: state, staleDate: nil),
                                         pushType: nil)
            activity = a
            activityRouteID = routeID
            lastState = state
            lastPushAt = Date()
            lastPushRemaining = remaining
        } catch {
            LogStore.shared.appendFromAnywhere("Live Activity not started: \(error.localizedDescription)")
        }
    }

    private func push(_ state: HaloNavAttributes.ContentState, remaining: Double,
                      to activity: Activity<HaloNavAttributes>) {
        lastState = state
        lastPushAt = Date()
        lastPushRemaining = remaining
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func end(_ activity: Activity<HaloNavAttributes>) {
        let final = finalState()
        self.activity = nil
        activityRouteID = nil
        lastState = nil
        let content = final.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = final == nil
            ? .immediate : .after(Date().addingTimeInterval(dismissAfter))
        Task { await activity.end(content, dismissalPolicy: policy) }
    }

    // MARK: - Content

    private var format: UnitFormat { settings.unitFormat }

    private func contentState(for nav: GuidanceController.NavState) -> HaloNavAttributes.ContentState {
        let f = format
        var instruction = nav.turn.instructionText
        var distance = f.distance(nav.turnDistance)
        if nav.turn == .arrival {
            if nav.turnDistance > 30 {
                instruction = String(localized: "Destination")
            } else {
                distance = ""
            }
        }
        var turn = nav.turn.rawValue
        var symbol = nav.turn.systemImage
        if nav.wrongWay {
            // Shown like off-route (the warning tint), with the U-turn.
            turn = "wrongWay"
            symbol = "arrow.uturn.backward"
            instruction = String(localized: "Wrong way")
            distance = ""
        }
        let speed = nav.speed.map { f.speedParts($0) }
        let remaining = f.distanceParts(nav.remaining)
        return .init(turn: turn,
                     symbol: symbol,
                     distance: distance,
                     instruction: instruction,
                     speedValue: speed?.value ?? "—",
                     speedUnit: speed?.unit ?? f.speedParts(0).unit,
                     distanceValue: remaining.value,
                     distanceUnit: remaining.unit,
                     progress: nav.progress,
                     offRoute: nav.turn == .offRoute || nav.wrongWay,
                     haloConnected: nav.haloConnected,
                     lightOn: lightOn,
                     ended: false)
    }

    /// Final Lock Screen state: arrival / stopped, average speed and distance ridden.
    private func finalState() -> HaloNavAttributes.ContentState? {
        guard let s = guidance.summary else {
            guard var last = lastState else { return nil }
            last.ended = true
            return last
        }
        let f = format
        let avg = f.speedParts(s.averageSpeed)
        let ridden = f.distanceParts(s.distance)
        return .init(turn: s.completed ? TurnKind.arrival.rawValue : "stopped",
                     symbol: s.completed ? TurnKind.arrival.systemImage : "flag.fill",
                     distance: "",
                     instruction: s.completed ? TurnKind.arrival.instructionText
                                              : String(localized: "Ride ended"),
                     speedValue: avg.value,
                     speedUnit: avg.unit,
                     distanceValue: ridden.value,
                     distanceUnit: ridden.unit,
                     progress: guidance.progress,
                     offRoute: false,
                     haloConnected: connection.state == .connected,
                     lightOn: lightOn,
                     ended: true)
    }

    private var lightOn: Bool {
        connection.state == .connected && (connection.controller?.lightOn ?? false)
    }
}
