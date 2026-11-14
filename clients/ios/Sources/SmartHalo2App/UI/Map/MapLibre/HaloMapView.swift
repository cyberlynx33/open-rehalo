import SwiftUI
import UIKit
import Combine
import CoreLocation
import MapKit
import MapLibre

/// What the MapLibre map shows on top of its base: the route (halo, lime line, arrows along it), the
/// other options dimmed, the destination, start, finish and stops, the downloaded areas' outlines.
struct HaloMapContent: Equatable {
    var route: GPXRoute?
    /// `GPXRoute ==` is by id: bumped when the geometry changes under the same id (an inverted or
    /// rerouted ride, docs/MAP_MATCHING_SPEC.md §9.3).
    var routeRevision = 0
    var alternatives: [GPXRoute] = []
    var destination: Destination?
    var stops: [CLLocationCoordinate2D] = []
    /// MapLibre's own blue dot and heading beam (the Map tab); Navigating draws `RiderMarker` instead.
    var showsUserLocation = false
    var downloadedOutlines: [[CLLocationCoordinate2D]] = []

    static func == (a: HaloMapContent, b: HaloMapContent) -> Bool {
        a.route == b.route && a.routeRevision == b.routeRevision && a.alternatives == b.alternatives
            && a.destination == b.destination && a.showsUserLocation == b.showsUserLocation
            && a.stops.count == b.stops.count && a.downloadedOutlines.count == b.downloadedOutlines.count
            && zip(a.stops, b.stops).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }
}

/// Where the map looks, in MapKit's terms (`distance` = the camera's height at pitch 0), so
/// `FollowCamera`'s output converts straight into `MLNMapCamera`.
struct HaloMapCamera: Equatable {
    var center: CLLocationCoordinate2D
    var distance: CLLocationDistance
    var heading: CLLocationDirection = 0
    var pitch: Double = 0

    init(center: CLLocationCoordinate2D, distance: CLLocationDistance, heading: CLLocationDirection = 0, pitch: Double = 0) {
        self.center = center; self.distance = distance; self.heading = heading; self.pitch = pitch
    }

    init(_ camera: MLNMapCamera) {
        self.init(center: camera.centerCoordinate, distance: camera.altitude, heading: camera.heading,
                  pitch: Double(camera.pitch))
    }

    init(_ camera: MapCamera) {
        self.init(center: camera.centerCoordinate, distance: camera.distance, heading: camera.heading, pitch: camera.pitch)
    }

    var mapLibre: MLNMapCamera {
        MLNMapCamera(lookingAtCenter: center, altitude: distance, pitch: CGFloat(pitch), heading: heading)
    }

    static func == (a: HaloMapCamera, b: HaloMapCamera) -> Bool {
        a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude
            && a.distance == b.distance && a.heading == b.heading && a.pitch == b.pitch
    }
}

/// A camera move the screen asks of the map, done once: a new `id` is a new move.
struct HaloMapMove: Equatable {
    enum Kind {
        case camera(HaloMapCamera)
        /// Fit these coordinates, inside the content insets plus a margin.
        case frame([CLLocationCoordinate2D])
        /// MapLibre's own user tracking: the blue dot centred, turned to the heading or north up.
        case follow(heading: Bool)
        case stopFollowing
        /// Turn north up over the same spot.
        case north
    }

    let id = UUID()
    let kind: Kind
    var animated = true

    init(_ kind: Kind, animated: Bool = true) {
        self.kind = kind
        self.animated = animated
    }

    static func == (a: HaloMapMove, b: HaloMapMove) -> Bool { a.id == b.id }
}

/// What the map tells the screen.
enum HaloMapEvent {
    /// The style finished loading (the layers are on).
    case styleLoaded
    /// A gesture started moving the camera.
    case gestureBegan
    /// The camera came to rest; `byUser` after a gesture.
    case cameraSettled(HaloMapCamera, byUser: Bool)
    /// MapLibre's user tracking changed (a gesture ends it).
    case trackingChanged(following: Bool, heading: Bool)
    case tap
    case longPress(CLLocationCoordinate2D)
}

/// The map's latest camera, kept out of SwiftUI state so following it every frame doesn't redraw the
/// screen (`LiveCamera`'s twin for MapLibre).
final class LiveMapCamera {
    var camera: HaloMapCamera?
}

/// The MapLibre map (docs/APP_SPEC.md M17): `MLNMapView` for SwiftUI, with the Halo look. The base
/// style and the layers come from `MapLayerSelection`; the content is a GeoJSON source per kind; the
/// camera is moved with `HaloMapMove`s, or driven at display rate by a `FollowCamera` (Navigating),
/// whose rider marker rides along as an annotation. Gestures, taps and long presses come back as
/// `HaloMapEvent`s. Attribution: MapLibre's own (i) button for the style and every raster source, and
/// `MapAttributionBar` on the screen.
struct HaloMapView: UIViewRepresentable {
    var layers: MapLayerSelection
    var content: HaloMapContent
    var move: HaloMapMove?
    /// Edges the chrome covers: framing and the ornaments keep clear of them.
    var insets: UIEdgeInsets = .zero
    var interactive = true
    var allowsPitch = true
    /// Navigating: the camera follows this at display rate while `followEnabled`.
    var follow: FollowCamera?
    var followEnabled = false
    var live: LiveMapCamera?
    var onEvent: (HaloMapEvent) -> Void = { _ in }

    /// Route line widths and the dimmed alternatives, as `RouteMapLayers` draws them on MapKit.
    static let haloWidth: CGFloat = 16
    static let lineWidth: CGFloat = 5
    static let alternativeWidth: CGFloat = 4
    static let haloOpacity: CGFloat = 0.22
    /// One direction arrow along the route every this many points.
    static let arrowSpacing: CGFloat = 120
    /// Margin inside the content insets when framing a route.
    static let frameMargin: CGFloat = 40

    func makeUIView(context: Context) -> MLNMapView {
        MapLibreSetup.configure()
        let map = MLNMapView(frame: .zero, styleURL: layers.base.styleURL)
        map.delegate = context.coordinator
        map.backgroundColor = UIColor(Theme.bg)
        map.compassView.compassVisibility = .hidden        // the screen has its own orientation button
        map.showsScale = true
        map.scaleBarPosition = .topLeft
        map.logoViewPosition = .bottomLeft
        map.attributionButtonPosition = .bottomRight
        map.attributionButton.tintColor = UIColor(Theme.textDim)
        map.isPitchEnabled = allowsPitch
        map.isScrollEnabled = interactive
        map.isZoomEnabled = interactive
        map.isRotateEnabled = interactive
        if interactive {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
            // MapLibre's double tap zooms: a single tap waits to see it isn't the first of two.
            for recognizer in map.gestureRecognizers ?? [] {
                if let double = recognizer as? UITapGestureRecognizer, double.numberOfTapsRequired == 2 {
                    tap.require(toFail: double)
                }
            }
            map.addGestureRecognizer(tap)
            let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
            hold.minimumPressDuration = 0.5
            map.addGestureRecognizer(hold)
        }
        context.coordinator.map = map
        context.coordinator.apply(self)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.apply(self)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    /// On the main actor: MapLibre calls its delegate on the main thread, which the `nonisolated`
    /// delegate methods assume (`MainActor.assumeIsolated`), as do the follow camera's publishers.
    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        var onEvent: (HaloMapEvent) -> Void = { _ in }
        var live: LiveMapCamera?

        private var styleLoaded = false
        private var layers = MapLayerSelection()
        private var content = HaloMapContent()
        private var appliedContent: HaloMapContent?
        private var appliedLayers: MapLayerSelection?
        private var lastMove: UUID?
        private var pendingMove: HaloMapMove?
        private var insets = UIEdgeInsets.zero
        private var gestureInProgress = false

        private var follow: FollowCamera?
        private var followEnabled = false
        private var followBag = Set<AnyCancellable>()
        private let rider = RiderAnnotation()
        private weak var riderView: RiderAnnotationView?
        private var riderOnMap = false

        // Identifiers of what this view adds to the style.
        private enum ID {
            static let topoSource = "halo-topo", topoLayer = "halo-topo-layer"
            static let satelliteSource = "halo-satellite", satelliteLayer = "halo-satellite-layer"
            static let demSource = "halo-dem", hillshadeLayer = "halo-hillshade"
            static let cycleSource = "halo-cycle", cycleLayer = "halo-cycle-layer"
            static let areasSource = "halo-areas", areasLayer = "halo-areas-layer"
            static let routeSource = "halo-route", routeHalo = "halo-route-halo", routeLine = "halo-route-line"
            static let routeArrows = "halo-route-arrows"
            static let alternativesSource = "halo-alternatives", alternativesLayer = "halo-alternatives-layer"
            static let pointsSource = "halo-points", pointsLayer = "halo-points-layer"
            static let arrowImage = "halo-arrow"
            static let startImage = "halo-start", finishImage = "halo-finish"
            static let destinationImage = "halo-destination", stopImage = "halo-stop"
        }

        // MARK: Applying the view's state

        func apply(_ view: HaloMapView) {
            onEvent = view.onEvent
            live = view.live
            guard let map else { return }
            if insets != view.insets {
                insets = view.insets
                map.contentInset = view.insets
                map.scaleBarMargins = CGPoint(x: 8, y: view.insets.top + 8)
                map.logoViewMargins = CGPoint(x: 8, y: view.insets.bottom + 8)
                map.attributionButtonMargins = CGPoint(x: 8, y: view.insets.bottom + 8)
            }
            if map.styleURL != view.layers.base.styleURL {
                styleLoaded = false
                appliedLayers = nil
                appliedContent = nil
                map.styleURL = view.layers.base.styleURL     // the layers come back in `didFinishLoading`
            }
            layers = view.layers
            content = view.content
            if styleLoaded {
                applyLayers()
                applyContent()
            }
            if map.showsUserLocation != view.content.showsUserLocation {
                map.showsUserLocation = view.content.showsUserLocation
            }
            bind(view.follow, enabled: view.followEnabled)
            if let move = view.move, move.id != lastMove {
                lastMove = move.id
                if styleLoaded || !Self.needsStyle(move) { perform(move) } else { pendingMove = move }
            }
        }

        /// Moves that wait for the style (and, with it, the view's first layout): the user tracking
        /// needs the location layer; framing needs the view's size.
        private static func needsStyle(_ move: HaloMapMove) -> Bool {
            switch move.kind {
            case .follow, .frame: return true
            case .camera, .stopFollowing, .north: return false
            }
        }

        private func perform(_ move: HaloMapMove) {
            guard let map else { return }
            switch move.kind {
            case .camera(let camera):
                map.setCamera(camera.mapLibre, animated: move.animated)
            case .frame(let coordinates):
                guard let bounds = Self.bounds(of: coordinates) else { return }
                let margin = HaloMapView.frameMargin
                map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: margin, left: margin, bottom: margin, right: margin),
                                               animated: move.animated, completionHandler: nil)
            case .follow(let heading):
                map.showsUserHeadingIndicator = heading
                map.setUserTrackingMode(heading ? .followWithHeading : .follow, animated: move.animated, completionHandler: nil)
                if !heading { map.setDirection(0, animated: move.animated) }
            case .stopFollowing:
                map.setUserTrackingMode(.none, animated: false, completionHandler: nil)
            case .north:
                map.setDirection(0, animated: move.animated)
            }
        }

        /// The smallest box round `coordinates`, at least 400 m across so a short route isn't a dot.
        static func bounds(of coordinates: [CLLocationCoordinate2D]) -> MLNCoordinateBounds? {
            guard let first = coordinates.first else { return nil }
            var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
            for c in coordinates {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
            let minimumSpan = 400.0 / 111_320
            if maxLat - minLat < minimumSpan { let mid = (minLat + maxLat) / 2; minLat = mid - minimumSpan / 2; maxLat = mid + minimumSpan / 2 }
            let lonSpan = minimumSpan / max(0.01, cos((minLat + maxLat) / 2 * .pi / 180))
            if maxLon - minLon < lonSpan { let mid = (minLon + maxLon) / 2; minLon = mid - lonSpan / 2; maxLon = mid + lonSpan / 2 }
            return MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                                       ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        }

        // MARK: Layers

        /// The style's first symbol layer: the rasters go under the labels, the route over everything.
        private func firstLabelLayer(_ style: MLNStyle) -> MLNStyleLayer? {
            style.layers.first { $0 is MLNSymbolStyleLayer }
        }

        private func applyLayers() {
            guard let map, let style = map.style, appliedLayers != layers else { return }
            appliedLayers = layers
            // Start clean: what was there is removed, then what's on is added, ground first.
            for id in [ID.topoLayer, ID.satelliteLayer, ID.hillshadeLayer, ID.cycleLayer, ID.areasLayer] {
                if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
            }
            for id in [ID.topoSource, ID.satelliteSource, ID.demSource, ID.cycleSource, ID.areasSource] {
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
            }
            let labels = firstLabelLayer(style)
            func insert(_ layer: MLNStyleLayer) {
                if let labels { style.insertLayer(layer, below: labels) } else { style.addLayer(layer) }
            }
            if layers.overlays.contains(.topo) || layers.overlays.contains(.satellite) {
                let satellite = layers.overlays.contains(.satellite)
                let source = MLNRasterTileSource(
                    identifier: satellite ? ID.satelliteSource : ID.topoSource,
                    tileURLTemplates: [satellite ? MapLayerCatalog.ignSatelliteTiles : MapLayerCatalog.ignTopoTiles],
                    options: [.tileSize: MapLayerCatalog.rasterTileSize,
                              .maximumZoomLevel: MapLayerCatalog.ignMaximumZoom,
                              .attributionHTMLString: satellite ? MapLayerCatalog.ignSatelliteCredit : MapLayerCatalog.ignTopoCredit])
                style.addSource(source)
                let layer = MLNRasterStyleLayer(identifier: satellite ? ID.satelliteLayer : ID.topoLayer, source: source)
                insert(layer)
            }
            if layers.overlays.contains(.hillshade) {
                let dem = MLNRasterDEMSource(
                    identifier: ID.demSource, tileURLTemplates: [MapLayerCatalog.terrainTiles],
                    options: [.tileSize: MapLayerCatalog.terrainTileSize,
                              .maximumZoomLevel: MapLayerCatalog.terrainMaximumZoom,
                              .demEncoding: MLNDEMEncoding.terrarium.rawValue,
                              .attributionHTMLString: MapLayerCatalog.terrainCredit])
                style.addSource(dem)
                let shade = MLNHillshadeStyleLayer(identifier: ID.hillshadeLayer, source: dem)
                shade.hillshadeExaggeration = NSExpression(forConstantValue: 0.5)
                shade.hillshadeShadowColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.6))
                shade.hillshadeHighlightColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.25))
                shade.hillshadeAccentColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.2))
                insert(shade)
            }
            if layers.overlays.contains(.cycle) {
                let source = MLNRasterTileSource(
                    identifier: ID.cycleSource, tileURLTemplates: [MapLayerCatalog.cycleTiles],
                    options: [.tileSize: MapLayerCatalog.rasterTileSize,
                              .maximumZoomLevel: MapLayerCatalog.cycleMaximumZoom,
                              .attributionHTMLString: MapLayerCatalog.cycleCredit + " · " + MapLayerCatalog.osmCredit])
                style.addSource(source)
                let layer = MLNRasterStyleLayer(identifier: ID.cycleLayer, source: source)
                layer.rasterOpacity = NSExpression(forConstantValue: 0.9)
                insert(layer)
            }
            if layers.overlays.contains(.downloaded) {
                let polygons = content.downloadedOutlines.compactMap { ring -> MLNPolygonFeature? in
                    guard ring.count >= 3 else { return nil }
                    var coords = ring
                    return MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
                }
                let source = MLNShapeSource(identifier: ID.areasSource, shape: MLNShapeCollectionFeature(shapes: polygons), options: nil)
                style.addSource(source)
                let layer = MLNLineStyleLayer(identifier: ID.areasLayer, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor(Theme.info))
                layer.lineWidth = NSExpression(forConstantValue: 2)
                layer.lineDashPattern = NSExpression(forConstantValue: [2, 2])
                layer.lineOpacity = NSExpression(forConstantValue: 0.8)
                style.addLayer(layer)
            }
            // The route layers were added before the ground changed under them: put them back on top.
            for id in [ID.alternativesLayer, ID.routeHalo, ID.routeLine, ID.routeArrows, ID.pointsLayer] {
                if let layer = style.layer(withIdentifier: id) {
                    style.removeLayer(layer)
                    style.addLayer(layer)
                }
            }
        }

        // MARK: Content

        private func applyContent() {
            guard let map, let style = map.style, appliedContent != content else { return }
            let outlinesChanged = appliedContent?.downloadedOutlines.count != content.downloadedOutlines.count
            appliedContent = content
            registerImages(style)

            // The route: one source, three layers (halo, line, arrows).
            let routeShape: MLNShape? = content.route.map { route in
                var coords = route.points
                return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            }
            if let existing = style.source(withIdentifier: ID.routeSource) as? MLNShapeSource {
                existing.shape = routeShape ?? MLNShapeCollectionFeature(shapes: [])
            } else {
                let source = MLNShapeSource(identifier: ID.routeSource, shape: routeShape ?? MLNShapeCollectionFeature(shapes: []), options: nil)
                style.addSource(source)
                let halo = MLNLineStyleLayer(identifier: ID.routeHalo, source: source)
                halo.lineColor = NSExpression(forConstantValue: UIColor(Theme.accent).withAlphaComponent(HaloMapView.haloOpacity))
                halo.lineWidth = NSExpression(forConstantValue: HaloMapView.haloWidth)
                halo.lineCap = NSExpression(forConstantValue: "round")
                halo.lineJoin = NSExpression(forConstantValue: "round")
                let line = MLNLineStyleLayer(identifier: ID.routeLine, source: source)
                line.lineColor = NSExpression(forConstantValue: UIColor(Theme.accent))
                line.lineWidth = NSExpression(forConstantValue: HaloMapView.lineWidth)
                line.lineCap = NSExpression(forConstantValue: "round")
                line.lineJoin = NSExpression(forConstantValue: "round")
                let arrows = MLNSymbolStyleLayer(identifier: ID.routeArrows, source: source)
                arrows.symbolPlacement = NSExpression(forConstantValue: "line")
                arrows.symbolSpacing = NSExpression(forConstantValue: HaloMapView.arrowSpacing)
                arrows.iconImageName = NSExpression(forConstantValue: ID.arrowImage)
                arrows.iconRotationAlignment = NSExpression(forConstantValue: "map")
                arrows.iconAllowsOverlap = NSExpression(forConstantValue: true)
                arrows.iconIgnoresPlacement = NSExpression(forConstantValue: true)
                // The alternatives draw under the route.
                let altSource = MLNShapeSource(identifier: ID.alternativesSource, shape: MLNShapeCollectionFeature(shapes: []), options: nil)
                style.addSource(altSource)
                let alt = MLNLineStyleLayer(identifier: ID.alternativesLayer, source: altSource)
                alt.lineColor = NSExpression(forConstantValue: UIColor(Theme.textDim).withAlphaComponent(0.7))
                alt.lineWidth = NSExpression(forConstantValue: HaloMapView.alternativeWidth)
                alt.lineCap = NSExpression(forConstantValue: "round")
                alt.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(alt)
                style.addLayer(halo)
                style.addLayer(line)
                style.addLayer(arrows)
                // Start, finish, destination and stops: one symbol layer, the image named by the feature.
                let points = MLNShapeSource(identifier: ID.pointsSource, shape: MLNShapeCollectionFeature(shapes: []), options: nil)
                style.addSource(points)
                let marks = MLNSymbolStyleLayer(identifier: ID.pointsLayer, source: points)
                marks.iconImageName = NSExpression(forKeyPath: "image")
                marks.iconAllowsOverlap = NSExpression(forConstantValue: true)
                marks.iconIgnoresPlacement = NSExpression(forConstantValue: true)
                marks.iconAnchor = NSExpression(forConstantValue: "center")
                style.addLayer(marks)
            }
            if let alt = style.source(withIdentifier: ID.alternativesSource) as? MLNShapeSource {
                let lines = content.alternatives.map { route -> MLNPolylineFeature in
                    var coords = route.points
                    return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                }
                alt.shape = MLNShapeCollectionFeature(shapes: lines)
            }
            if let points = style.source(withIdentifier: ID.pointsSource) as? MLNShapeSource {
                var features: [MLNPointFeature] = []
                func add(_ c: CLLocationCoordinate2D, _ image: String) {
                    let f = MLNPointFeature()
                    f.coordinate = c
                    f.attributes = ["image": image]
                    features.append(f)
                }
                if let route = content.route {
                    if let start = route.start { add(start, ID.startImage) }
                    if let end = route.end { add(end, ID.finishImage) }
                }
                for stop in content.stops { add(stop, ID.stopImage) }
                if let d = content.destination { add(d.coordinate, ID.destinationImage) }
                points.shape = MLNShapeCollectionFeature(shapes: features)
            }
            if outlinesChanged, layers.overlays.contains(.downloaded) {
                appliedLayers = nil
                applyLayers()
            }
        }

        /// The markers as images: the SwiftUI views the MapKit map uses, rendered once per style.
        private func registerImages(_ style: MLNStyle) {
            guard style.image(forName: ID.arrowImage) == nil else { return }
            style.setImage(Self.arrowImage(), forName: ID.arrowImage)
            if let start = Self.render(RouteEndpointMarker(isFinish: false)) { style.setImage(start, forName: ID.startImage) }
            if let finish = Self.render(RouteEndpointMarker(isFinish: true)) { style.setImage(finish, forName: ID.finishImage) }
            if let stop = Self.render(RouteStopMarker()) { style.setImage(stop, forName: ID.stopImage) }
            if let pin = Self.render(DestinationPinMarker()) { style.setImage(pin, forName: ID.destinationImage) }
        }

        private static func render<V: View>(_ view: V) -> UIImage? {
            let renderer = ImageRenderer(content: view)
            renderer.scale = UIScreen.main.scale
            return renderer.uiImage
        }

        /// A chevron pointing up (the direction of travel), dark on the lime line.
        private static func arrowImage() -> UIImage {
            let size = CGSize(width: 12, height: 12)
            let format = UIGraphicsImageRendererFormat()
            format.scale = UIScreen.main.scale
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                let p = UIBezierPath()
                p.move(to: CGPoint(x: 2, y: 9))
                p.addLine(to: CGPoint(x: 6, y: 3))
                p.addLine(to: CGPoint(x: 10, y: 9))
                p.lineWidth = 2.5
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                UIColor(Theme.onAccent).setStroke()
                p.stroke()
                _ = ctx
            }
        }

        // MARK: Follow camera (Navigating)

        private func bind(_ follow: FollowCamera?, enabled: Bool) {
            followEnabled = enabled
            guard follow !== self.follow else { return }
            followBag.removeAll()
            self.follow = follow
            guard let follow else {
                if riderOnMap, let map { map.removeAnnotation(rider); riderOnMap = false }
                return
            }
            // `FollowCamera` publishes from its display link, on the main thread.
            follow.$camera
                .sink { [weak self] cam in
                    MainActor.assumeIsolated {
                        guard let self, let cam, self.followEnabled, !follow.paused, !self.gestureInProgress else { return }
                        self.map?.setCamera(HaloMapCamera(cam).mapLibre, animated: false)
                    }
                }
                .store(in: &followBag)
            follow.$rider
                .sink { [weak self] coordinate in
                    MainActor.assumeIsolated { self?.moveRider(to: coordinate) }
                }
                .store(in: &followBag)
            Publishers.CombineLatest(follow.$riderHeading, follow.$beamSpread)
                .sink { [weak self] heading, spread in
                    MainActor.assumeIsolated {
                        guard let self, let map = self.map else { return }
                        self.riderView?.update(rotation: heading - map.direction, beamSpread: spread)
                    }
                }
                .store(in: &followBag)
        }

        private func moveRider(to coordinate: CLLocationCoordinate2D?) {
            guard let map else { return }
            guard let coordinate else {
                if riderOnMap { map.removeAnnotation(rider); riderOnMap = false }
                return
            }
            rider.coordinate = coordinate
            if !riderOnMap {
                map.addAnnotation(rider)
                riderOnMap = true
            }
        }

        // MARK: MLNMapViewDelegate (main thread, hence `assumeIsolated`)

        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated {
                styleLoaded = true
                appliedLayers = nil
                appliedContent = nil
                applyLayers()
                applyContent()
                if let move = pendingMove {
                    pendingMove = nil
                    perform(move)
                }
                onEvent(.styleLoaded)
            }
        }

        nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            LogStore.shared.appendFromAnywhere("MapLibre: \(error.localizedDescription)")
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            MainActor.assumeIsolated {
                if Self.isGesture(reason), !gestureInProgress {
                    gestureInProgress = true
                    onEvent(.gestureBegan)
                }
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
            MainActor.assumeIsolated {
                live?.camera = HaloMapCamera(mapView.camera)
                if let follow, riderOnMap {
                    riderView?.update(rotation: follow.riderHeading - mapView.direction, beamSpread: follow.beamSpread)
                }
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            MainActor.assumeIsolated {
                let camera = HaloMapCamera(mapView.camera)
                live?.camera = camera
                let byUser = Self.isGesture(reason)
                if byUser { gestureInProgress = false }
                onEvent(.cameraSettled(camera, byUser: byUser))
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            MainActor.assumeIsolated {
                onEvent(.trackingChanged(following: mode != .none, heading: mode == .followWithHeading))
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            MainActor.assumeIsolated {
                guard annotation is RiderAnnotation else { return nil }
                let id = "rider"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? RiderAnnotationView)
                    ?? RiderAnnotationView(reuseIdentifier: id)
                riderView = view
                if let follow { view.update(rotation: follow.riderHeading - mapView.direction, beamSpread: follow.beamSpread) }
                return view
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        nonisolated private static func isGesture(_ reason: MLNCameraChangeReason) -> Bool {
            let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn,
                                                   .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
            return !reason.isDisjoint(with: gestures)
        }

        // MARK: Gestures

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onEvent(.tap)
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map else { return }
            let point = recognizer.location(in: map)
            onEvent(.longPress(map.convert(point, toCoordinateFrom: map)))
        }
    }
}

/// The rider on the Navigating map: `RiderMarker`, moved every frame by `FollowCamera`.
final class RiderAnnotation: MLNPointAnnotation {}

final class RiderAnnotationView: MLNAnnotationView {
    private let host = UIHostingController(rootView: RiderMarker())
    static let side: CGFloat = 96

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        scalesWithViewingDistance = false
        isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(rotation: Double, beamSpread: Double?) {
        host.rootView = RiderMarker(rotation: rotation, beamSpread: beamSpread)
    }
}

/// A stop on the way (a via point), between the start and finish markers in weight.
struct RouteStopMarker: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))
            .padding(2)
    }
}

/// The destination pin (MapKit's `Marker` on the Apple map).
struct DestinationPinMarker: View {
    var body: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(Theme.onAccent, Theme.accent)
            .padding(2)
    }
}
