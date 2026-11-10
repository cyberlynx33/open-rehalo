import SwiftUI
import MapKit
import UIKit

/// Map tab (UX_DESIGN §4.2): the map first, on a dark muted style with the
/// rider's position and nothing selected at launch. There is no bottom card: the search pill turns
/// into the selected route or destination (`MapContextPill`) and ▶ NAVEGAR floats at the bottom
/// right (`MapActionRow`). Tapping the map hides every control, tab bar included; another tap
/// brings them back. Navigating opens full screen (`NavigatingView`). Works without a Halo
/// (guidance then stays on the phone) and in demo mode (simulated rider).
///
/// Destinations: the search pill finds routes and places (`SearchSheet`), and touching and holding
/// the map drops a pin. A destination gets Apple's routes in the rider's `RouteProfile`
/// (`DestinationRouter`), ▶ NAVEGAR turn by turn or Compass as the crow flies. Navigating a route
/// from more than `farFromStart` away asks
/// how to get to its start.
struct MapTab: View {
    @EnvironmentObject private var guidance: GuidanceController
    @EnvironmentObject private var selection: RouteSelection
    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: RouteLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    /// The first `onAppear` places the camera; later ones (back from another tab) leave it alone.
    @State private var appeared = false
    @State private var importError: String?
    @State private var showNav = false
    /// View controls (layers + 3D/2D). "3D" = the camera is tilted (the terrain is always 3D, so
    /// tilting never has to wait for a style change); navigation itself always stays flat.
    @AppStorage("sh2.map.base") private var base: MapBase = .map
    @AppStorage("sh2.map.tiltHintShown") private var tiltHintShown = false
    @State private var is3D = false
    @State private var showTiltHint = false
    @State private var live = LiveCamera()
    /// North / Compass (remembered) or Free; see `MapOrientation`. Compass is MapKit's own
    /// heading-follow (the iPhone compass, with Apple's beam on the blue dot).
    @State private var orientation: MapOrientation = .north
    /// The map's heading while Free (for the button's north arrow).
    @State private var freeHeading: Double = 0

    // Destinations (search / long-press pin).
    @StateObject private var search = PlaceSearch()
    @State private var showSearch = false
    @State private var destination: Destination?
    /// Apple's routes to the destination, and the one the rider chose.
    @State private var routeOptions: [RoutedDestination] = []
    @State private var routeChoice = 0
    @State private var routing = false
    @State private var routeError: String?
    @State private var destinationSaved = false
    /// A route to navigate whose start is far away: the "how do I get there" question.
    @State private var farStart: FarStart?
    @State private var leadingIn = false
    /// ▶ on a recent route: started once the search sheet is gone, so the "far from the start"
    /// question isn't presented from a sheet on its way out.
    @State private var routeToStart: SavedRoute?

    // Hiding the controls (see `mapTapped`).
    @State private var chromeHidden = false
    @State private var pendingToggle: Task<Void, Never>?
    @State private var lastPinAt = Date.distantPast
    @AppStorage("sh2.map.hideHintShown") private var hideHintShown = false
    @State private var showHideHint = false

    // Notices.
    @AppStorage("sh2.map.firstRunHintShown") private var firstRunHintShown = false
    @State private var showNoHalo = false
    @State private var noHaloTask: Task<Void, Never>?

    struct FarStart {
        let route: GPXRoute
        let distance: Double
    }

    /// Farther than this from a route's start, NAVEGAR asks how to get there.
    static let farFromStart: CLLocationDistance = 500

    private var fmt: UnitFormat { settings.unitFormat }
    private var routed: RoutedDestination? {
        routeOptions.indices.contains(routeChoice) ? routeOptions[routeChoice] : nil
    }
    private var otherOptions: [Int] { routeOptions.indices.filter { $0 != routeChoice } }
    private var demoRoute: GPXRoute? { RouteSelection.demoRoute(isDemo: connection.isDemo) }

    /// A route or destination is in play (destinations win, as on the map).
    private var hasContext: Bool { destination != nil || selection.route != nil }
    /// Location denied and no simulated rider: nothing could be navigated, so the actions stay off
    /// and the `.locationOff` notice says why.
    private var locationBlocked: Bool { guidance.locationDenied && !connection.isDemo }
    private var contextKey: String? {
        destination.map { "destination \($0.id)" } ?? selection.route.map { "route \($0.id)" }
    }

    var body: some View {
        // Full screen: the map runs under the status and tab bars (hiding the tab bar must not
        // resize it, or the camera would jump), with everything else floating on it.
        ZStack(alignment: .top) {
            map.ignoresSafeArea()
            VStack(spacing: Theme.Space.s) {
                topArea
                if destination != nil && !chromeHidden && !guidance.locationDenied {
                    RouteOptionsBar(profile: settings.routeProfile, options: routeOptions.map(optionStats),
                                    choice: routeChoice, onProfile: chooseProfile, onOption: chooseOption)
                        .padding(.horizontal, Theme.Space.l)
                        .transition(.opacity)
                }
                if connection.isDemo {
                    DemoBadge()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, Theme.Space.l)
                }
                if showTiltHint && !chromeHidden { TiltHint() }
                if !chromeHidden, let notice {
                    MapNotice(kind: notice, onOpenSettings: openSettings, onFirstRun: openSearch)
                        .padding(.horizontal, Theme.Space.l)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: notice)
        }
        .overlay(alignment: .bottomTrailing) { bottomControls }
        .overlay(alignment: .bottom) {
            if showHideHint && chromeHidden {
                HideControlsHint().padding(.bottom, Theme.Space.xl)
            }
        }
        .toolbar(chromeHidden ? .hidden : .automatic, for: .tabBar)
        .sheet(isPresented: $showSearch, onDismiss: startRouteFromSearch) {
            SearchSheet(search: search,
                        onRoute: { saved in
                            clearDestination()
                            importError = library.select(saved) ? nil
                                : String(localized: "Couldn't read this route's GPX file.")
                        },
                        onNavigate: { routeToStart = $0 },
                        onPlace: { setDestination($0, center: true) },
                        onMyRoutes: { router.tab = .routes },
                        onImport: { handleImport($0) },
                        onDemo: demoAction)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.surface2)
                .environmentObject(settings)
                .modelContainer(RouteLibrary.shared.container)
                .haloTheme()
        }
        .confirmationDialog(Text("You're \(fmt.distance(farStart?.distance ?? 0)) from the start"),
                            isPresented: Binding(get: { farStart != nil }, set: { if !$0 { farStart = nil } }),
                            titleVisibility: .visible, presenting: farStart) { far in
            Button("Lead me to the start") { leadToStart(far.route) }
            Button("Start at the nearest point") { go(far.route, joinNearest: true) }
            Button("Go on my own") { go(far.route) }
            Button("Cancel", role: .cancel) {}
        }
        .sensoryFeedback(.impact, trigger: destination?.id)
        .fullScreenCover(isPresented: $showNav) {
            NavigatingView {
                showNav = false
                guidance.dismissSummary()
            }
            .environmentObject(guidance)
            .environmentObject(settings)
            .environmentObject(connection)
            .environmentObject(router)
            .environmentObject(selection)
            .haloTheme()
        }
        .onAppear {
            // The map opens on the rider: ask if Onboarding didn't get an answer.
            if !guidance.locationAuthorized && !guidance.locationDenied { guidance.requestLocationPermission() }
            // A fresh fix for `currentCoordinate` (the "far from the start" question).
            guidance.primeLocation()
            if !appeared {
                // Only once: `onAppear` also fires on every return from another tab, and reframing
                // then would throw away wherever the rider had put the map.
                appeared = true
                orientation = settings.mapOrientation
                if orientation == .compass && guidance.locationAuthorized {
                    camera = .userLocation(followsHeading: true, fallback: userFallback)
                } else {
                    if orientation == .compass { orientation = .north }    // no location: can't follow
                    frameSelection(animated: false)
                }
            }
            consumePendingNavigation()
            if guidance.following || guidance.summary != nil { showNav = true }
        }
        .onChange(of: selection.route) { _, _ in
            clearDestination()
            frameSelection(animated: true)
        }
        .onChange(of: selection.pendingNavigation) { _, pending in
            if pending { consumePendingNavigation() }
        }
        .onChange(of: guidance.following) { _, following in
            if following { showNav = true }
        }
        .onChange(of: contextKey) { _, key in contextChanged(key) }
        .onChange(of: router.tab) { _, tab in
            if tab != .map { setChromeHidden(false) }
        }
        .onChange(of: showNav) { _, showing in
            if !showing { setChromeHidden(false) }
        }
        .task(id: importError) {
            guard importError != nil else { return }
            setChromeHidden(false)
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { importError = nil }
        }
    }

    // MARK: - Overlays

    /// `.pitch` must stay in the interaction modes: without it MapKit ignores the camera's pitch
    /// and draws flat. Steep tilts come from `steepTilt`, which takes over MapKit's own gesture.
    private var map: some View {
        // Touch and hold drops a pin; a tap shows or hides the controls; the map keeps its own
        // gestures (a pan cancels the hold).
        MapReader { proxy in
            baseMap
                .simultaneousGesture(dropPinGesture(proxy))
                .simultaneousGesture(TapGesture().onEnded { mapTapped() })
        }
        .accessibilityAction(named: Text(chromeHidden ? "Show the controls" : "Hide the controls")) {
            setChromeHidden(!chromeHidden)
        }
    }

    private var baseMap: some View {
        Map(position: $camera, interactionModes: .all) {
            ForEach(otherOptions, id: \.self) { i in
                RouteMapLayers.alternative(routeOptions[i].route, overlayLevel: .aboveRoads)
            }
            if let route = shownRoute {
                // Overlays above labels force MapKit back to flat; keep the route at road level.
                RouteMapLayers.route(route, overlayLevel: .aboveRoads)
            }
            if let destination {
                Marker(destination.name, systemImage: "mappin", coordinate: destination.coordinate)
                    .tint(Theme.accent)
            }
            UserAnnotation()
        }
        .mapStyle(.halo(base, elevated: true))
        .onMapCameraChange(frequency: .continuous) { context in
            live.camera = context.camera
            let tilted = context.camera.pitch > 1
            if tilted != is3D { is3D = tilted }
            if orientation == .free { freeHeading = context.camera.heading }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // Turning the map by hand in North sets it Free.
            let h = context.camera.heading
            if orientation == .north, camera.positionedByUser, abs(Geo.angleDelta(from: 0, to: h)) > 3 {
                freeHeading = h
                orientation = .free
            }
        }
        .onChange(of: camera.followsUserHeading) { was, now in
            // Anything that takes the camera off heading-follow (a pan, a tilt, framing the route,
            // 3D) leaves Compass for Free, with the map where it is.
            if was, !now, orientation == .compass {
                freeHeading = live.camera?.heading ?? 0
                orientation = .free
            }
        }
        .steepTilt($camera, live: live)
        .mapControls { MapScaleView() }
        .onChange(of: is3D) { _, tilted in
            if tilted { showTiltHintOnce() }
        }
        .safeAreaPadding(mapInsets)
    }

    /// Fixed, so hiding the controls never moves the map: what's framed clears the floating bars,
    /// and Apple's logo and legal link stay visible above the tab bar and the destination's actions.
    private var mapInsets: EdgeInsets {
        EdgeInsets(top: destination != nil ? 175 : 120, leading: 0, bottom: destination != nil ? 170 : 100, trailing: 0)
    }

    private func dropPinGesture(_ proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      let c = proxy.convert(drag.location, from: .local) else { return }
                dropPin(at: c)
            }
    }

    /// The route on the map: the destination's while there is one, else the selected route.
    private var shownRoute: GPXRoute? { destination != nil ? routed?.route : selection.route }

    /// The top bar, or with the controls hidden the chip naming what's on the map.
    private var topArea: some View {
        ZStack(alignment: .top) {
            topBar
                .opacity(chromeHidden ? 0 : 1)
                .offset(y: chromeHidden && !reduceMotion ? -14 : 0)
                .allowsHitTesting(!chromeHidden)
            if chromeHidden, let miniChipText {
                MapMiniChip(text: miniChipText)
                    .padding(.top, Theme.Space.s)
                    .padding(.horizontal, Theme.Space.l)
                    .transition(.opacity)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.s) {
            if hasContext {
                MapContextPill(title: destination?.name ?? selection.route?.name ?? "",
                               closeLabel: destination != nil ? "Remove the pin" : "Remove the route",
                               onOpen: openSearch,
                               onClose: clearContext) { contextDetail }
            } else {
                searchPill
            }
            HaloStatusButton(compact: true)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
    }

    @ViewBuilder private var contextDetail: some View {
        if let destination {
            if let routed {
                detailStats(stats(routed))
            } else if routing {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Finding a route…").font(.footnote).foregroundStyle(Theme.textDim)
                }
            } else if let routeError {
                Text(verbatim: routeError).font(.footnote).foregroundStyle(Theme.warn).lineLimit(2)
            } else if let subtitle = destination.subtitle {
                Text(verbatim: subtitle).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1)
            }
        } else if let route = selection.route {
            detailStats(statsLine(route))
        }
    }

    private func detailStats(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.metricFont(.footnote, weight: .semibold))
            .foregroundStyle(Theme.textDim)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var miniChipText: String? {
        if let destination {
            guard let routed else { return destination.name }
            return "\(destination.name) · \(fmt.distance(routed.route.length))"
        }
        return selection.route.map { "\($0.name) · \(fmt.distance($0.length))" }
    }

    private var searchPill: some View {
        Button(action: openSearch) {
            Label("Search a place or a route", systemImage: "magnifyingglass")
                .lineLimit(1)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: Theme.minTarget, alignment: .leading)
                .background(Theme.surface.opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Thumb column over the floating actions; together they fade out when the controls hide.
    private var bottomControls: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.m) {
            mapButtons
            if let actionMode {
                MapActionRow(mode: actionMode,
                             onNavigate: { destination != nil ? navigateToDestination() : startNavigation() },
                             onCompass: compassToDestination,
                             onSave: saveDestination)
                    .disabled(locationBlocked)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: actionMode)
        .padding(Theme.Space.l)
        .opacity(chromeHidden ? 0 : 1)
        .offset(y: chromeHidden && !reduceMotion ? 24 : 0)
        .allowsHitTesting(!chromeHidden)
    }

    private var mapButtons: some View {
        VStack(spacing: Theme.Space.s) {
            // Thumb column, least to most used from the top: view controls, then route / me.
            MapViewMenu(base: $base, is3D: is3D, isCompass: orientation == .compass,
                        toggle3D: toggle3D, toggleCompass: toggleCompass)
            if orientation != .north {
                OrientationButton(orientation: orientation, mapHeading: freeHeading,
                                  action: toggleOrientation)
            }
            if shownRoute != nil {
                MapRoundButton(systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                               label: "Show the whole route") { frameSelection(animated: true) }
            }
            MapRoundButton(systemImage: "location.fill", label: "Center on my position") { recenter() }
        }
    }

    private var actionMode: MapActionRow.Mode? {
        if destination != nil {
            return .destination(routed: routed != nil, routing: routing, saved: destinationSaved)
        }
        return selection.route == nil ? nil : .route(busy: leadingIn)
    }

    /// One message at a time, most urgent first.
    private var notice: MapNotice.Kind? {
        if leadingIn { return .leadingIn }
        if let importError { return .error(importError) }
        if guidance.locationDenied && !connection.isDemo { return .locationOff }
        if showNoHalo { return .noHalo }
        if let routed, !routed.notices.isEmpty { return .advice(routed.notices.prefix(2).joined(separator: "\n")) }
        if !firstRunHintShown && !hasContext && library.isEmpty { return .firstRun }
        return nil
    }

    private var demoSubtitle: String {
        String(localized: "Demo route")
    }

    private var demoAction: (() -> Void)? {
        guard let demoRoute else { return nil }
        return { useDemoRoute(demoRoute) }
    }

    private func statsLine(_ route: GPXRoute) -> String {
        var parts = [fmt.distance(route.length)]
        if let gain = route.totalGain { parts.append("↗ " + fmt.elevation(gain)) }
        parts.append("~" + fmt.duration(route.estimatedDuration))
        return parts.joined(separator: " · ")
    }

    private func stats(_ r: RoutedDestination) -> String {
        optionStats(r) + " · " + r.travel.label
    }

    private func optionStats(_ r: RoutedDestination) -> String {
        fmt.distance(r.route.length) + " · ~" + fmt.duration(r.expectedTravelTime)
    }

    // MARK: - Showing and hiding the controls

    /// A tap waits to see whether it's the start of MapKit's double-tap zoom: the second tap of a
    /// double tap lands here too, and only cancels the first. Long presses can also end in a tap,
    /// hence `lastPinAt`.
    private func mapTapped() {
        if let pendingToggle {
            pendingToggle.cancel()
            self.pendingToggle = nil
            return
        }
        guard !voiceOverEnabled, Date.now.timeIntervalSince(lastPinAt) > 0.4 else { return }
        pendingToggle = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            pendingToggle = nil
            setChromeHidden(!chromeHidden)
        }
    }

    private func setChromeHidden(_ hidden: Bool) {
        guard hidden != chromeHidden else { return }
        withAnimation(.easeInOut(duration: 0.22)) { chromeHidden = hidden }
        if hidden { showHideHintOnce() }
    }

    private func showHideHintOnce() {
        guard !hideHintShown else { return }
        hideHintShown = true
        withAnimation { showHideHint = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { showHideHint = false }
        }
    }

    /// A new route or destination (or none): show the controls, and the "no Halo" note for a moment.
    private func contextChanged(_ key: String?) {
        setChromeHidden(false)
        noHaloTask?.cancel()
        showNoHalo = false
        guard key != nil else { return }
        firstRunHintShown = true
        guard connection.state != .connected else { return }
        showNoHalo = true
        noHaloTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { showNoHalo = false }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Actions

    /// The bundled demo route goes through the library (saved + marked used); the built-in loop is
    /// only a fallback in demo mode if the bundle has no `DemoRoute.gpx`.
    private func useDemoRoute(_ fallback: GPXRoute) {
        if let saved = library.addDemoRoute(), library.select(saved) { return }
        selection.select(fallback, subtitle: demoSubtitle)
    }

    /// NAVEGAR on the selected route; far from its start, ask first (lead me there / nearest point /
    /// on my own).
    private func startNavigation() {
        guard let route = selection.route else { return }
        // Also reached from Route detail's NAVIGATE: without Location the ride would only ever say
        // "Waiting for GPS…", so show the notice instead of starting.
        guard !locationBlocked else { setChromeHidden(false); return }
        library.markUsed(id: route.id)
        importError = nil
        if !connection.isDemo, let here = currentCoordinate, let start = route.points.first {
            let d = Geo.distance(here, start)
            if d > Self.farFromStart {
                farStart = FarStart(route: route, distance: d)
                return
            }
        }
        go(route)
    }

    private func go(_ route: GPXRoute, leadIn: RoutedDestination? = nil, joinNearest: Bool = false) {
        guidance.start(route, leadIn: leadIn, joinNearest: joinNearest)
        showNav = true
    }

    /// "Lead me to the start": Apple's route to the start, ridden first as part of the same ride.
    private func leadToStart(_ route: GPXRoute) {
        guard let start = route.points.first else { return }
        leadingIn = true
        Task {
            defer { leadingIn = false }
            do {
                let leadIn = try await DestinationRouter.route(to: Destination(coordinate: start, name: route.name),
                                                               profile: settings.routeProfile)
                go(route, leadIn: leadIn)
            } catch {
                importError = String(localized: "Couldn't find a route to the start: \(error.localizedDescription)")
            }
        }
    }

    /// Where the rider is now, if Location is on: the guidance's fix when it is recent (it is primed
    /// on appear), else what CoreLocation last cached. Before the first fix of a launch the cache
    /// can be empty, which is why the fix is primed.
    private var currentCoordinate: CLLocationCoordinate2D? {
        guard guidance.locationAuthorized else { return nil }
        if let loc = guidance.lastLocation, Date().timeIntervalSince(loc.timestamp) < 300 { return loc.coordinate }
        return CLLocationManager().location?.coordinate ?? guidance.userCoord
    }

    // MARK: - Destinations

    private func openSearch() {
        firstRunHintShown = true
        search.query = ""
        if let cam = live.camera {
            search.setRegion(MKCoordinateRegion(center: cam.centerCoordinate,
                                                latitudinalMeters: max(cam.distance * 2, 5_000),
                                                longitudinalMeters: max(cam.distance * 2, 5_000)))
        }
        showSearch = true
    }

    /// Touch and hold: a pin named after its street once the reverse geocoding answers.
    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        lastPinAt = .now
        pendingToggle?.cancel()
        pendingToggle = nil
        setChromeHidden(false)
        let pin = Destination(coordinate: coordinate, name: String(localized: "Dropped pin"))
        setDestination(pin, center: false)
        Task {
            guard let named = await PlaceSearch.name(at: coordinate), destination?.id == pin.id else { return }
            destination?.name = named.name
            destination?.subtitle = named.subtitle
        }
    }

    private func setDestination(_ d: Destination, center: Bool) {
        destination = d
        clearRoutes()
        if center {
            let region = MKCoordinateRegion(center: d.coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { camera = .region(region) }
        }
        // Apple routes from the current location.
        guard !guidance.locationDenied else {
            routeError = String(localized: "Turn on Location to get a route.")
            return
        }
        if !guidance.locationAuthorized { guidance.requestLocationPermission() }
        loadRoutes(to: d)
    }

    /// Apple's routes to `d` in the rider's profile. An answer for another destination or profile is
    /// dropped.
    private func loadRoutes(to d: Destination) {
        let profile = settings.routeProfile
        routing = true
        Task {
            do {
                let options = try await DestinationRouter.routes(to: d, profile: profile, id: d.id)
                guard destination?.id == d.id, settings.routeProfile == profile else { return }
                routeOptions = options
                routing = false
                frameSelection(animated: true)
            } catch {
                guard destination?.id == d.id, settings.routeProfile == profile else { return }
                routing = false
                routeError = error.localizedDescription
            }
        }
    }

    private func chooseProfile(_ profile: RouteProfile) {
        guard profile != settings.routeProfile else { return }
        settings.routeProfile = profile
        clearRoutes()
        if let destination { loadRoutes(to: destination) }
    }

    private func chooseOption(_ option: Int) {
        routeChoice = option
        destinationSaved = false
        frameSelection(animated: true)
    }

    private func clearRoutes() {
        routeOptions = []
        routeChoice = 0
        routeError = nil
        destinationSaved = false
    }

    private func clearDestination() {
        destination = nil
        routing = false
        clearRoutes()
    }

    /// ✕ on the pill: a destination gives way to the selected route, if any; a route to the plain
    /// map. The camera stays where it is.
    private func clearContext() {
        if destination != nil {
            clearDestination()
        } else {
            selection.clear()
        }
    }

    /// ▶ on a recent route in the search sheet, now that the sheet is gone.
    private func startRouteFromSearch() {
        guard let saved = routeToStart else { return }
        routeToStart = nil
        clearDestination()
        importError = library.select(saved, navigate: true) ? nil
            : String(localized: "Couldn't read this route's GPX file.")
    }

    private func navigateToDestination() {
        guard let d = destination, let r = routed else { return }
        search.remember(d)
        importError = nil
        // The pin may have got its name after the route was computed.
        guidance.start(GPXRoute(id: r.route.id, name: d.name, points: r.route.points), instructions: r.instructions,
                       routedSteps: r.steps)
        showNav = true
    }

    private func compassToDestination() {
        guard let d = destination else { return }
        search.remember(d)
        importError = nil
        guidance.startCompass(to: d, from: currentCoordinate)
        showNav = true
    }

    private func saveDestination() {
        guard let d = destination, let r = routed else { return }
        do {
            try library.importGPX(data: GPXWriter.data(name: d.name, points: r.route.points),
                                  fallbackName: d.name, source: .appleMaps)
            destinationSaved = true
        } catch {
            routeError = String(localized: "Couldn't save the route: \(error.localizedDescription)")
        }
    }

    /// M9's Route detail "▶ NAVEGAR" → `RouteSelection.select(_, navigate: true)` lands here.
    private func consumePendingNavigation() {
        guard selection.pendingNavigation else { return }
        selection.pendingNavigation = false
        startNavigation()
    }

    private func frameSelection(animated: Bool) {
        guard let route = shownRoute, !route.points.isEmpty else { return }
        // In 3D keep looking at the route from an angle instead of dropping to a flat frame.
        let target: MapCameraPosition = is3D ? .camera(.overview(of: route))
                                             : .rect(route.boundingMapRect())
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.5)) { camera = target }
        } else {
            camera = target
        }
    }

    /// 3D tilts the camera for real (and lowers it if MapKit would cap the tilt); 2D goes back to
    /// a flat, north-up map over the same spot.
    private func toggle3D() {
        guard let cam = live.camera else { return }
        let next = !is3D ? MapTilt.tilted(cam, pitch: MapTilt.pitch3D)
                        : MapCamera(centerCoordinate: cam.centerCoordinate, distance: cam.distance,
                                    heading: 0, pitch: 0)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { camera = .camera(next) }
    }

    private func showTiltHintOnce() {
        guard !tiltHintShown else { return }
        tiltHintShown = true
        withAnimation { showTiltHint = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showTiltHint = false }
        }
    }

    /// Centre on the rider, back in the remembered orientation when the map was Free.
    private func recenter() {
        if guidance.locationDenied {
            frameSelection(animated: true)
            return
        }
        if !guidance.locationAuthorized { guidance.requestLocationPermission() }
        if orientation == .free { orientation = settings.mapOrientation }
        if orientation == .compass {
            startCompass()
        } else {
            turnNorth(thenFollow: true)
        }
    }

    private var userFallback: MapCameraPosition {
        selection.route.map { MapCameraPosition.rect($0.boundingMapRect()) } ?? .automatic
    }

    /// The round button: North ⇄ Compass (remembered); from Free, north up over the same spot.
    private func toggleOrientation() {
        switch orientation {
        case .north:
            startCompass()
        case .compass:
            let following = camera.followsUserLocation
            orientation = .north
            settings.mapOrientation = .north
            turnNorth(thenFollow: following)
        case .free:
            orientation = .north
            settings.mapOrientation = .north
            turnNorth(thenFollow: false)
        }
    }

    /// Compass in the view menu: on from any orientation, off back to north up.
    private func toggleCompass() {
        if orientation == .compass {
            toggleOrientation()
        } else {
            startCompass()
        }
    }

    private func startCompass() {
        guard !guidance.locationDenied else { return }
        if !guidance.locationAuthorized { guidance.requestLocationPermission() }
        orientation = .compass
        settings.mapOrientation = .compass
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
            camera = .userLocation(followsHeading: true, fallback: userFallback)
        }
    }

    /// Turn the map north up where it is; `thenFollow` then hands the camera to the user's location
    /// (plain location-follow keeps whatever heading it starts from, hence the two steps).
    private func turnNorth(thenFollow: Bool) {
        let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.5)
        let follow = { withAnimation(animation) { camera = .userLocation(fallback: userFallback) } }
        guard let cam = live.camera, abs(Geo.angleDelta(from: 0, to: cam.heading)) > 0.5 else {
            if thenFollow { follow() }
            return
        }
        let north = MapCamera(centerCoordinate: cam.centerCoordinate, distance: cam.distance,
                              heading: 0, pitch: cam.pitch)
        withAnimation(animation) {
            camera = .camera(north)
        } completion: {
            if thenFollow { follow() }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            // Saved to the library (Routes tab) and selected here.
            let saved = try library.importGPX(from: url, defaultSource: .files)
            importError = library.select(saved) ? nil : String(localized: "Couldn't read this route's GPX file.")
        } catch {
            importError = String(localized: "Couldn't load GPX: \(error.localizedDescription)")
        }
    }
}

/// Round floating map button (recenter, frame route, compass…). `size` is 48 pt on the Map tab;
/// Navigating passes `Theme.minTargetRiding` (UX_DESIGN §6: 56 pt on a ride).
struct MapRoundButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var isOn: Bool = false
    var rotation: Double = 0
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                .frame(width: size, height: size)
                .background(isOn ? Theme.accent : Theme.surface.opacity(0.94), in: Circle())
                .overlay(Circle().strokeBorder(isOn ? Color.clear : Theme.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
