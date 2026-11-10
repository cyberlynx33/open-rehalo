import SwiftUI
import MapKit
import UIKit

/// Navigating, full screen (UX_DESIGN §4.3): turn banner on top, follow-camera map (Compass by
/// default; the round button toggles North ⇄ Compass — remembered — and turning or moving the map
/// by hand sets it Free until Centre, see `MapOrientation`), metrics panel with progress bar, light
/// toggle, PARAR (confirmed) and ⋯ menu. When the ride ends it shows the summary; `onDone` closes.
///
/// Nothing automatic on start/stop (no light/alarm changes, UX §10). No phone-side off-route sound,
/// only a warning haptic. If the Halo drops, a non-blocking banner says guidance continues here.
struct NavigatingView: View {
    let onDone: () -> Void

    @EnvironmentObject private var guidance: GuidanceController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var connection: HaloConnection
    @Environment(\.scenePhase) private var scenePhase

    /// Held, not observed: only `NavMap` and `CompassPill` redraw on its per-frame updates.
    @State private var follow = FollowCamera()
    @State private var orientation: MapOrientation = .compass
    /// The map's heading while Free (for the button's north arrow).
    @State private var freeHeading: Double = 0
    @State private var confirmStop = false

    private var fmt: UnitFormat { settings.unitFormat }

    var body: some View {
        Group {
            if let summary = guidance.summary, !guidance.following {
                RideSummaryView(summary: summary, format: fmt, onDone: onDone)
            } else {
                navigating
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - Navigating

    private var navigating: some View {
        ZStack {
            map.ignoresSafeArea()
            VStack(spacing: 0) {
                topArea
                Spacer(minLength: 0)
                bottomPanel
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            orientation = settings.navOrientation
            feedFix()
            follow.start()
        }
        .onDisappear { follow.stop() }
        .onChange(of: scenePhase) { _, phase in
            // No map to draw in the background: stop the display link and the compass.
            if phase == .active { follow.start() } else if phase == .background { follow.stop() }
        }
        .onChange(of: guidance.fixCount) { _, _ in feedFix() }
        .sensoryFeedback(.warning, trigger: guidance.offRoute) { old, new in !old && new }
        .sensoryFeedback(.warning, trigger: guidance.wrongWayAlerts)
        .alert("End the route?", isPresented: $confirmStop) {
            Button("Keep going", role: .cancel) {}
            Button("End", role: .destructive) { guidance.stop() }
        } message: {
            Text("The ring will stop guiding you.")
        }
    }

    private var map: some View {
        NavMap(follow: follow, route: guidance.route, startHeading: guidance.heading,
               orientation: $orientation, freeHeading: $freeHeading)
    }

    private func feedFix() {
        guard let loc = guidance.lastLocation else { return }
        follow.update(fix: loc, speed: guidance.speed, course: guidance.heading)
    }

    /// The round button: North ⇄ Compass (remembered); from Free, back to North.
    private func toggleOrientation() {
        setOrientation(orientation == .north ? .compass : .north)
    }

    /// Centre (only shown in Free): follow again in the remembered mode.
    private func recenter() { setOrientation(settings.navOrientation) }

    private func setOrientation(_ o: MapOrientation) {
        orientation = o
        if o != .free { settings.navOrientation = o }
    }

    // MARK: Top: turn banner + notices + compass

    private var topArea: some View {
        VStack(spacing: Theme.Space.s) {
            turnBanner
            if let left = guidance.toStart {
                HStack {
                    NavPill(systemImage: "arrow.right.circle",
                            text: "To the start · \(fmt.distance(left))", color: Theme.info)
                    Spacer(minLength: 0)
                }
            }
            if guidance.haloLost {
                NoticeBanner(systemImage: "antenna.radiowaves.left.and.right.slash",
                             text: "Halo disconnected. Guidance continues on the phone.")
            }
            if guidance.wrongWay {
                WrongWayBanner(canInvert: guidance.canInvert,
                               invert: { guidance.invert() },
                               ignore: { guidance.ignoreWrongWay() })
            }
            HStack(alignment: .top) {
                if guidance.simulated {
                    NavPill(systemImage: "location.circle", text: "Simulated GPS", color: Theme.info)
                } else if !guidance.hasFix {
                    NavPill(systemImage: "location.magnifyingglass", text: "Waiting for GPS…", color: Theme.warn)
                } else if orientation == .compass {
                    CompassPill(follow: follow)
                }
                Spacer(minLength: 0)
                VStack(spacing: Theme.Space.s) {
                    // Riding targets (UX_DESIGN §6: 56 pt), unlike the Map tab's 48 pt column.
                    OrientationButton(orientation: orientation, mapHeading: freeHeading,
                                      size: Theme.minTargetRiding, action: toggleOrientation)
                    if orientation == .free {
                        MapRoundButton(systemImage: "location.fill", label: "Center on my position",
                                       size: Theme.minTargetRiding, action: recenter)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
    }

    @ViewBuilder private var turnBanner: some View {
        if let target = guidance.compassTarget, guidance.following {
            // As the crow flies: the arrow points at the destination, straight-line distance.
            TurnBanner(kind: .straight, distance: fmt.distance(guidance.remainingDistance),
                       instruction: target.name, iconRotation: .degrees(guidance.compassBearing))
        } else if guidance.offRoute {
            TurnBanner(kind: .offRoute, distance: fmt.distance(guidance.offRouteDistance),
                       instruction: guidance.reachedOrigin ? nil : String(localized: "To the route's start"),
                       iconRotation: guidance.offRouteBearing.map { Angle.degrees(Double($0)) })
        } else if guidance.nextTurn == .arrival {
            let d = guidance.nextTurnDistance
            if d > 30 {
                TurnBanner(kind: .arrival, distance: fmt.distance(d),
                           instruction: String(localized: "Destination"))
            } else {
                TurnBanner(kind: .arrival)
            }
        } else {
            TurnBanner(kind: guidance.nextTurn, distance: fmt.distance(guidance.nextTurnDistance),
                       instruction: guidance.nextTurnText)
        }
    }

    // MARK: Bottom: metrics, progress, controls

    private var bottomPanel: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Button(action: cyclePrimary) { primaryMetric }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Changes the metric"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(fmt.distanceParts(guidance.remainingDistance), label: "remaining")
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(value: "\(percent)", unit: "%", label: "done")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            RouteProgressBar(progress: guidance.progress)
                .accessibilityElement()
                .accessibilityLabel(Text("Route progress"))
                .accessibilityValue(Text(verbatim: "\(percent) %"))
            HStack(spacing: Theme.Space.m) {
                NavLightButton(controller: connection.controller,
                               enabled: connection.state == .connected)
                Button { confirmStop = true } label: {
                    Label("STOP", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(HaloButtonStyle(kind: .destructive, riding: true))
                moreMenu
            }
        }
        .padding(Theme.Space.l)
        .background {
            // Panel sheet; extends under the home indicator.
            UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card,
                                   topTrailingRadius: Theme.Radius.card,
                                   style: .continuous)
                .fill(Theme.surface.opacity(0.97))
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var percent: Int { Int((guidance.progress * 100).rounded(.down)) }

    // MARK: Primary metric (tap cycles speed / time / climb left — remembered)

    private var primaryOptions: [NavPrimaryMetric] {
        guidance.route?.hasElevation == true ? NavPrimaryMetric.allCases : [.speed, .elapsed]
    }

    private var primary: NavPrimaryMetric {
        primaryOptions.contains(settings.navPrimaryMetric) ? settings.navPrimaryMetric : .speed
    }

    private func cyclePrimary() {
        let list = primaryOptions
        let i = list.firstIndex(of: primary) ?? 0
        settings.navPrimaryMetric = list[(i + 1) % list.count]
    }

    @ViewBuilder private var primaryMetric: some View {
        switch primary {
        case .speed:
            if let s = guidance.speed {
                MetricView(fmt.speedParts(s), label: "speed")
            } else {
                MetricView(value: "—", unit: fmt.speedParts(0).unit, label: "speed")
            }
        case .elapsed:
            MetricView(value: RideClock.string(guidance.elapsed), label: "time")
        case .remainingGain:
            MetricView(fmt.elevationParts(guidance.remainingGain ?? 0), label: "climb left")
        }
    }

    private var moreMenu: some View {
        Menu {
            Picker("Main metric", selection: Binding(get: { primary },
                                                    set: { settings.navPrimaryMetric = $0 })) {
                ForEach(primaryOptions) { m in
                    Text(m.label).tag(m)
                }
            }
            Button(action: toggleOrientation) {
                Label(orientation == .north ? LocalizedStringKey("Switch to compass")
                                            : LocalizedStringKey("Switch to north up"),
                      systemImage: "location.north.line")
            }
        } label: {
            NavSquareLabel(systemImage: "ellipsis")
        }
        .accessibilityLabel(Text("More options"))
    }
}

// MARK: - Pieces

/// The Navigating map, fed by `FollowCamera` at display rate. Its own view so the per-frame camera
/// redraws only the map, not the whole screen. A pinch zooms and keeps following; turning or
/// moving the map sets it Free (loose until Centre).
private struct NavMap: View {
    @ObservedObject var follow: FollowCamera
    let route: GPXRoute?
    let startHeading: Double
    @Binding var orientation: MapOrientation
    @Binding var freeHeading: Double

    @State private var position: MapCameraPosition = .automatic
    @State private var userDriving = false
    @State private var live = LiveCamera()

    /// Heading the map shows right now: the follow camera's, or the fingers' while they drive it.
    private var mapHeading: Double {
        orientation == .free || userDriving ? (live.camera?.heading ?? 0) : follow.cameraHeading
    }

    var body: some View {
        Map(position: $position, interactionModes: [.zoom, .rotate, .pan]) {
            if let route {
                RouteMapLayers.route(route)
            }
            if let c = follow.rider {
                Annotation("You", coordinate: c, anchor: .center) {
                    RiderMarker(rotation: follow.riderHeading - mapHeading, beamSpread: follow.beamSpread)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.halo)
        .mapControls { MapScaleView() }
        .onAppear {
            follow.orientation = orientation
            if let start = route?.start, follow.rider == nil {
                position = .camera(MapCamera(centerCoordinate: start, distance: follow.distance,
                                             heading: orientation == .north ? 0 : startHeading, pitch: 0))
            }
        }
        .onReceive(follow.$camera) { cam in
            guard let cam, !follow.paused, orientation != .free else { return }
            position = .camera(cam)
        }
        .onChange(of: position.positionedByUser) { _, byUser in
            guard byUser else { return }
            follow.paused = true
            userDriving = true
        }
        .onChange(of: orientation) { old, new in
            follow.orientation = new
            if new == .free {
                follow.paused = true
                freeHeading = live.camera?.heading ?? 0
            } else if old == .free {
                follow.resume(from: live.camera)
            }
        }
        .onMapCameraChange(frequency: .continuous) { context in
            live.camera = context.camera
            if orientation == .free { freeHeading = context.camera.heading }
        }
        .onMapCameraChange(frequency: .onEnd) { context in settle(context.camera) }
    }

    /// A gesture ended: a zoom alone keeps following at the new distance; a turn or a move of more
    /// than a little sets the map Free.
    private func settle(_ cam: MapCamera) {
        guard userDriving else { return }
        userDriving = false
        follow.distance = min(5000, max(150, cam.distance))
        guard orientation != .free else { return }
        let turned = abs(Geo.angleDelta(from: follow.cameraHeading, to: cam.heading)) > 8
        let moved = follow.rider.map { Geo.distance($0, cam.centerCoordinate) > cam.distance * 0.15 } ?? false
        if turned || moved {
            orientation = .free
        } else {
            follow.resume(from: cam)
        }
    }
}

/// "Compass unreliable · using GPS" while Compass mode can't trust the iPhone's compass.
private struct CompassPill: View {
    @ObservedObject var follow: FollowCamera

    var body: some View {
        if follow.compassUnreliable {
            NavPill(systemImage: "location.north.line", text: "Compass unreliable · using GPS",
                    color: Theme.warn)
        }
    }
}

/// Square 56 pt control (light, ⋯) next to PARAR.
struct NavSquareLabel: View {
    let systemImage: String
    var isOn: Bool = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
            .frame(width: Theme.minTargetRiding, height: Theme.minTargetRiding)
            .background(isOn ? Theme.accent : Theme.surface2,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : Theme.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// Front-light toggle via the shared controller (disabled without a connected Halo).
struct NavLightButton: View {
    let controller: DeviceController?
    let enabled: Bool

    var body: some View {
        if let controller {
            Inner(controller: controller, enabled: enabled)
        } else {
            NavSquareLabel(systemImage: "lightbulb")
                .opacity(0.4)
                .accessibilityLabel(Text("Front light"))
                .accessibilityValue(Text("Halo not connected"))
        }
    }

    private struct Inner: View {
        @ObservedObject var controller: DeviceController
        let enabled: Bool

        var body: some View {
            Button {
                let on = !controller.lightOn
                Task { await controller.setLight(on: on) }
            } label: {
                NavSquareLabel(systemImage: controller.lightOn ? "lightbulb.fill" : "lightbulb",
                               isOn: controller.lightOn && enabled)
            }
            .buttonStyle(PressableStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .sensoryFeedback(.impact(weight: .medium), trigger: controller.lightOn)
            .accessibilityLabel(Text("Front light"))
            .accessibilityAddTraits(controller.lightOn ? [.isSelected] : [])
        }
    }
}

/// Thin route progress bar.
struct RouteProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, min(1, progress)) * g.size.width)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

/// Non-blocking warning strip (e.g. Halo dropped mid-ride).
struct NoticeBanner: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.warn)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.surface.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Riding the route the wrong way (MAP_MATCHING_SPEC §9.2): what's happening and what to do about it.
/// The ring shows its U-turn meanwhile.
struct WrongWayBanner: View {
    let canInvert: Bool
    let invert: () -> Void
    let ignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.uturn.backward").font(.headline.weight(.bold))
                Text("Wrong way").font(.headline.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.warn)
            Text("You are riding the route the other way.")
                .font(.subheadline)
                .foregroundStyle(Theme.text)
            HStack(spacing: Theme.Space.s) {
                if canInvert {
                    Button(action: invert) {
                        Label("Invert route", systemImage: "arrow.left.arrow.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, Theme.Space.l)
                            .frame(minHeight: Theme.minTargetRiding)
                            .background(Theme.warn, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: ignore) {
                    Text("Ignore")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.warn)
                        .padding(.horizontal, Theme.Space.l)
                        .frame(minHeight: Theme.minTargetRiding)
                        .overlay(Capsule().strokeBorder(Theme.warn.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.surface.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.6), lineWidth: 1)
        )
    }
}

/// Small status capsule over the map ("Simulated GPS", "Waiting for GPS…").
struct NavPill: View {
    let systemImage: String
    let text: LocalizedStringKey
    var color: Color = Theme.textDim

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.surface.opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// "12:34" / "1:05:12" ride clock.
enum RideClock {
    static func string(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Summary

/// End of ride: distance, time, average (UX §4.3).
struct RideSummaryView: View {
    let summary: GuidanceController.Summary
    let format: UnitFormat
    let onDone: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.m) {
                Image(systemName: summary.completed ? "checkmark" : "flag.checkered")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 96, height: 96)
                    .background(Theme.accent, in: Circle())
                    .symbolEffect(.bounce, value: appeared)
                    .accessibilityHidden(true)
                Group {
                    if summary.completed { Text("Route completed!") } else { Text("Route ended") }
                }
                .font(.title.weight(.heavy))
                .foregroundStyle(Theme.text)
                Text(verbatim: summary.routeName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
            HStack(alignment: .top, spacing: Theme.Space.m) {
                MetricView(format.distanceParts(summary.distance), label: "distance",
                           size: .medium, alignment: .center)
                    .frame(maxWidth: .infinity)
                MetricView(value: RideClock.string(summary.duration), label: "time",
                           size: .medium, alignment: .center)
                    .frame(maxWidth: .infinity)
                MetricView(format.speedParts(summary.averageSpeed), label: "average",
                           size: .medium, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
            .haloCard()
            Spacer(minLength: 0)
            PrimaryButton("Done", riding: true, action: onDone)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .haloScreenBackground()
        .onAppear { appeared = true }
    }
}
