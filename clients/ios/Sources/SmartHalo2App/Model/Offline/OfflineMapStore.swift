import Foundation
import Combine
import CoreLocation
import Network
import MapLibre

/// Offline maps for the MapLibre engine (docs/APP_SPEC.md M17), on `MLNOfflineStorage`: a corridor
/// `corridorWidth` wide round each saved route (zoom `corridorMinZoom`–`corridorMaxZoom`) and one
/// world pack per base style (zoom 0–1), which holds the style, its glyphs and sprites, so a map
/// opens without a connection at all. Each pack remembers what it is in its `context` (`Context`).
///
/// OpenFreeMap's terms allow offline downloads of at most `maxTilesPerDownload` tiles or
/// `maxBytesPerDownload` each, over at most four connections (`MapLibreSetup`): a corridor that would
/// take more tiles isn't downloaded, and a download that passes the bytes is stopped. The raster
/// layers (IGN, Mapterhorn, CyclOSM) aren't part of the packs: they're added at run time, outside the
/// style the packs download.
@MainActor
final class OfflineMapStore: ObservableObject {
    static let shared = OfflineMapStore()

    /// Metres each side of the route.
    static let corridorWidth = 1_000.0
    static let corridorMinZoom = 1.0
    static let corridorMaxZoom = 14.0
    static let worldMinZoom = 0.0
    static let worldMaxZoom = 1.0
    /// OpenFreeMap: "at most 3,000 tiles or 50 MB" per download.
    static let maxTilesPerDownload = 3_000
    static let maxBytesPerDownload: UInt64 = 50 * 1024 * 1024
    /// The corridor is a chain of squares round points this far apart along the route.
    static let sampleSpacing = 500.0
    /// Tiles of all zooms over the top zoom's count (a quarter per zoom down).
    static let zoomPyramidFactor = 4.0 / 3.0

    /// One pack, as the screen lists it.
    struct Area: Identifiable, Equatable {
        enum Kind: Equatable {
            case corridor(routeID: UUID?)
            case world
        }
        enum State: Equatable {
            case downloading(Double)
            case complete
            case paused
            case waitingForWiFi
            case failed(String)
        }

        let id: UUID
        var name: String
        var kind: Kind
        var style: MapBaseStyle
        var state: State
        var bytes: UInt64
        var tiles: UInt64
        /// The squares of a corridor (one ring each), for the "downloaded areas" layer.
        var outlines: [[CLLocationCoordinate2D]]
    }

    /// What a pack remembers about itself (`MLNOfflinePack.context`).
    struct Context: Codable {
        var id: UUID
        var name: String
        var routeID: UUID?
        var style: MapBaseStyle
        var world: Bool
        /// Corridor samples as `[lat, lon]`.
        var samples: [[Double]]
    }

    enum Outcome: Equatable {
        case started
        case alreadyThere
        case tooLarge(tiles: Int)
        case waitingForWiFi
        case failed(String)
    }

    @Published private(set) var areas: [Area] = []
    /// On Wi-Fi (or wired) right now.
    @Published private(set) var onWiFi = true
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private let monitor = NWPathMonitor()
    private var bag = Set<AnyCancellable>()
    /// Packs this launch asked for, not yet in `packs`.
    private var starting: Set<UUID> = []

    init(settings: AppSettings = .shared) {
        self.settings = settings
        MapLibreSetup.configure()
        let center = NotificationCenter.default
        for name in [Notification.Name.MLNOfflinePackProgressChanged, .MLNOfflinePackError,
                     .MLNOfflinePackMaximumMapboxTilesReached] {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in self?.packChanged(note) }
                .store(in: &bag)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in self?.networkChanged(wifi: wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "offline-maps.network"))
        reload()
    }

    // MARK: - Listing

    /// Re-read the packs from storage (they load on their own time: read again shortly after).
    func reload() {
        MLNOfflineStorage.shared.reloadPacks()
        refresh()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.refresh()
        }
    }

    private func refresh() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        areas = packs.compactMap(area(for:)).sorted { a, b in
            if a.kind == .world != (b.kind == .world) { return a.kind != .world }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for pack in packs where pack.state == .unknown { pack.requestProgress() }
    }

    private func area(for pack: MLNOfflinePack) -> Area? {
        guard let context = try? JSONDecoder().decode(Context.self, from: pack.context) else { return nil }
        let progress = pack.progress
        let state: Area.State
        switch pack.state {
        case .complete: state = .complete
        case .active:
            let expected = max(progress.countOfResourcesExpected, 1)
            state = .downloading(min(1, Double(progress.countOfResourcesCompleted) / Double(expected)))
        case .inactive: state = settings.offlineWiFiOnly && !onWiFi ? .waitingForWiFi : .paused
        case .invalid: state = .failed(String(localized: "This download is no longer valid."))
        case .unknown: state = .paused
        @unknown default: state = .paused
        }
        let samples = context.samples.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        return Area(id: context.id, name: context.name,
                    kind: context.world ? .world : .corridor(routeID: context.routeID),
                    style: context.style, state: state,
                    bytes: progress.countOfBytesCompleted, tiles: progress.countOfTilesCompleted,
                    outlines: samples.map { Self.square(around: $0, halfSide: Self.corridorWidth) })
    }

    /// Every corridor square, for the map's "downloaded areas" layer.
    var outlines: [[CLLocationCoordinate2D]] { areas.flatMap(\.outlines) }

    func hasCorridor(for routeID: UUID) -> Bool {
        areas.contains { $0.kind == .corridor(routeID: routeID) }
    }

    // MARK: - Downloads

    /// The corridor round `route` on the current base style (and the world pack it needs). Nothing
    /// when the map engine isn't MapLibre or the setting is off: `RouteLibrary` calls this on every
    /// saved route.
    func downloadIfWanted(route: GPXRoute, name: String, style: MapBaseStyle) {
        guard settings.mapEngine == .mapLibre, settings.offlineSaveWithRoute else { return }
        _ = download(route: route, name: name, style: style)
    }

    /// Download the corridor round `route` (zoom 1–14) on `style`, and make sure the style's world
    /// pack exists.
    @discardableResult
    func download(route: GPXRoute, name: String, style: MapBaseStyle) -> Outcome {
        guard !hasCorridor(for: route.id) else { return .alreadyThere }
        let samples = Self.samples(along: route)
        let tiles = Self.estimatedTiles(samples: samples, zoom: Int(Self.corridorMaxZoom))
        guard tiles <= Self.maxTilesPerDownload else { return .tooLarge(tiles: tiles) }
        ensureWorldPack(style)
        var polygons: [MLNPolygon] = []
        for c in samples {
            var ring = Self.square(around: c, halfSide: Self.corridorWidth)
            polygons.append(MLNPolygon(coordinates: &ring, count: UInt(ring.count)))
        }
        let region = MLNShapeOfflineRegion(styleURL: style.styleURL, shape: MLNMultiPolygon(polygons: polygons),
                                           fromZoomLevel: Self.corridorMinZoom, toZoomLevel: Self.corridorMaxZoom)
        let context = Context(id: UUID(), name: name, routeID: route.id, style: style, world: false,
                              samples: samples.map { [$0.latitude, $0.longitude] })
        return add(region, context: context)
    }

    /// The world at zoom 0–1 for `style`: its JSON, glyphs and sprites, so the map draws offline at all.
    func ensureWorldPack(_ style: MapBaseStyle) {
        guard !areas.contains(where: { $0.kind == .world && $0.style == style }) else { return }
        let world = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: -85, longitude: -180),
                                        ne: CLLocationCoordinate2D(latitude: 85, longitude: 180))
        let region = MLNTilePyramidOfflineRegion(styleURL: style.styleURL, bounds: world,
                                                 fromZoomLevel: Self.worldMinZoom, toZoomLevel: Self.worldMaxZoom)
        let name = style == .night ? String(localized: "World · Night") : String(localized: "World · Day")
        _ = add(region, context: Context(id: UUID(), name: name, routeID: nil, style: style, world: true, samples: []))
    }

    private func add(_ region: MLNOfflineRegion, context: Context) -> Outcome {
        guard let data = try? JSONEncoder().encode(context) else { return .failed("context") }
        let canStart = !settings.offlineWiFiOnly || onWiFi
        starting.insert(context.id)
        MLNOfflineStorage.shared.addPack(for: region, withContext: data) { [weak self] pack, error in
            Task { @MainActor in
                guard let self else { return }
                self.starting.remove(context.id)
                if let error {
                    self.lastError = error.localizedDescription
                    LogStore.shared.appendFromAnywhere("Offline maps: \(error.localizedDescription)")
                } else if canStart {
                    pack?.resume()
                }
                self.refresh()
            }
        }
        return canStart ? .started : .waitingForWiFi
    }

    func remove(_ area: Area) {
        guard let pack = pack(for: area) else { return }
        MLNOfflineStorage.shared.removePack(pack) { [weak self] error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription }
                self?.refresh()
            }
        }
    }

    /// Download again what has changed on the server (the pack's resources are marked stale).
    func update(_ area: Area) {
        guard let pack = pack(for: area) else { return }
        MLNOfflineStorage.shared.invalidatePack(pack) { [weak self] error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription } else { pack.resume() }
                self?.refresh()
            }
        }
    }

    func resume(_ area: Area) {
        pack(for: area)?.resume()
        refresh()
    }

    func pause(_ area: Area) {
        pack(for: area)?.suspend()
        refresh()
    }

    private func pack(for area: Area) -> MLNOfflinePack? {
        (MLNOfflineStorage.shared.packs ?? []).first {
            (try? JSONDecoder().decode(Context.self, from: $0.context))?.id == area.id
        }
    }

    // MARK: - Events

    private func packChanged(_ note: Notification) {
        guard let pack = note.object as? MLNOfflinePack else { return }
        if note.name == .MLNOfflinePackError, let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error {
            lastError = error.localizedDescription
        }
        if note.name == .MLNOfflinePackMaximumMapboxTilesReached {
            lastError = String(localized: "The offline tile limit was reached.")
            pack.suspend()
        }
        // OpenFreeMap's 50 MB per download: stop a corridor that passes it.
        if pack.state == .active, pack.progress.countOfBytesCompleted > Self.maxBytesPerDownload {
            pack.suspend()
            lastError = String(localized: "This area is over OpenFreeMap's 50 MB per download and was stopped.")
        }
        refresh()
    }

    /// Wi-Fi only: downloads wait for it and stop without it.
    private func networkChanged(wifi: Bool) {
        onWiFi = wifi
        guard settings.offlineWiFiOnly else { return }
        for pack in MLNOfflineStorage.shared.packs ?? [] {
            if wifi, pack.state == .inactive { pack.resume() }
            if !wifi, pack.state == .active { pack.suspend() }
        }
        refresh()
    }

    // MARK: - Geometry

    /// Points every `sampleSpacing` metres along the route, the end included.
    static func samples(along route: GPXRoute) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        var along = 0.0
        while along < route.length {
            out.append(route.coordinate(at: along))
            along += sampleSpacing
        }
        if let end = route.end { out.append(end) }
        return out
    }

    /// A closed square ring `halfSide` metres round `c`.
    static func square(around c: CLLocationCoordinate2D, halfSide: Double) -> [CLLocationCoordinate2D] {
        let dLat = halfSide / 111_320
        let dLon = halfSide / (111_320 * max(0.01, cos(c.latitude * .pi / 180)))
        return [CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude - dLon),
                CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude + dLon),
                CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon),
                CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude - dLon),
                CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude - dLon)]
    }

    /// How many tiles the corridor's squares cover at `zoom` and below, for OpenFreeMap's limit.
    static func estimatedTiles(samples: [CLLocationCoordinate2D], zoom: Int) -> Int {
        var tiles = Set<Int64>()
        let n = Double(1 << zoom)
        for c in samples {
            let ring = square(around: c, halfSide: corridorWidth)
            let xs = ring.map { tileX($0.longitude, n) }, ys = ring.map { tileY($0.latitude, n) }
            for x in (xs.min() ?? 0)...(xs.max() ?? 0) {
                for y in (ys.min() ?? 0)...(ys.max() ?? 0) { tiles.insert(Int64(x) << 32 | Int64(y)) }
            }
        }
        return Int((Double(tiles.count) * zoomPyramidFactor).rounded(.up))
    }

    private static func tileX(_ lon: Double, _ n: Double) -> Int {
        Int(((lon + 180) / 360 * n).rounded(.down))
    }

    private static func tileY(_ lat: Double, _ n: Double) -> Int {
        let rad = lat * .pi / 180
        return Int(((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n).rounded(.down))
    }
}
