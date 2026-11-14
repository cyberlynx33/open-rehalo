import Foundation
import SwiftUI

/// The MapLibre map's base styles and layers (docs/APP_SPEC.md M17), with where each comes from and
/// what it asks to be credited as. Everything here is free to use in an app; what each source allows
/// offline is in `OfflineMapStore`.
enum MapLayerCatalog {
    /// OpenFreeMap's hosted styles (OpenMapTiles schema, OpenStreetMap data): no key, no limits on
    /// views. `dark` is the night map; `liberty` the full-detail day map.
    static let nightStyleURL = URL(string: "https://tiles.openfreemap.org/styles/dark")!
    static let dayStyleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    /// Spain's official topographic map (MTN) and orthophoto (PNOA), WMTS in the web-mercator tile
    /// matrix set. Both CC BY 4.0 (`ows:AccessConstraints` in their capabilities).
    static let ignTopoTiles = "https://www.ign.es/wmts/mapa-raster?service=WMTS&request=GetTile&version=1.0.0"
        + "&layer=MTN&style=default&format=image/jpeg&tilematrixset=GoogleMapsCompatible"
        + "&tilematrix={z}&tilerow={y}&tilecol={x}"
    static let ignSatelliteTiles = "https://www.ign.es/wmts/pnoa-ma?service=WMTS&request=GetTile&version=1.0.0"
        + "&layer=OI.OrthoimageCoverage&style=default&format=image/jpeg&tilematrixset=GoogleMapsCompatible"
        + "&tilematrix={z}&tilerow={y}&tilecol={x}"
    static let ignMaximumZoom = 18.0

    /// Mapterhorn's terrain tiles: Terrarium-encoded, 512 px WebP; Spain from the IGN's digital
    /// terrain models (CC BY 4.0), the rest of the world from Copernicus GLO-30.
    static let terrainTiles = "https://tiles.mapterhorn.com/{z}/{x}/{y}.webp"
    static let terrainTileSize = 512
    static let terrainMaximumZoom = 15.0

    /// CyclOSM's "lite" overlay (cycle routes and infrastructure over any base), rendered by
    /// OpenStreetMap France under the OSMF tile usage policy: online only, never bulk-downloaded.
    static let cycleTiles = "https://a.tile-cyclosm.openstreetmap.fr/cyclosm-lite/{z}/{x}/{y}.png"
    static let cycleMaximumZoom = 19.0
    static let rasterTileSize = 256

    // Credits, as each source asks for them.
    static let osmCredit = "© OpenStreetMap contributors"
    static let openFreeMapCredit = "OpenFreeMap · © OpenMapTiles"
    static let ignTopoCredit = "© Instituto Geográfico Nacional (CC BY 4.0 ign.es)"
    static let ignSatelliteCredit = "PNOA © Instituto Geográfico Nacional (CC BY 4.0 scne.es)"
    static let terrainCredit = "Terrain: Mapterhorn (IGN CC BY 4.0, Copernicus)"
    static let cycleCredit = "CyclOSM (CC BY-SA 2.0)"
    static let mapLibreCredit = "MapLibre"
}

/// The base map: OpenFreeMap's night or day style.
enum MapBaseStyle: String, CaseIterable, Identifiable, Codable {
    case night, day

    var id: String { rawValue }

    var styleURL: URL {
        switch self {
        case .night: return MapLayerCatalog.nightStyleURL
        case .day: return MapLayerCatalog.dayStyleURL
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .night: return "Night"
        case .day: return "Day"
        }
    }

    var systemImage: String {
        switch self {
        case .night: return "moon.stars.fill"
        case .day: return "sun.max.fill"
        }
    }
}

/// A layer over the base map. Topo and Satellite replace the map's ground (they draw under its
/// labels); the others draw over it.
enum MapOverlay: String, CaseIterable, Identifiable, Codable {
    case topo, satellite, hillshade, cycle, downloaded

    var id: String { rawValue }

    /// Two of these can't both be on: one covers the other.
    var isGround: Bool { self == .topo || self == .satellite }

    var label: LocalizedStringKey {
        switch self {
        case .topo: return "Topo IGN"
        case .satellite: return "Satellite"
        case .hillshade: return "Relief"
        case .cycle: return "Cycle network"
        case .downloaded: return "Downloaded areas"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .topo: return "Spain's official topographic map (IGN, CC BY 4.0)."
        case .satellite: return "Spain's aerial orthophoto (IGN PNOA, CC BY 4.0)."
        case .hillshade: return "Shaded relief from Mapterhorn's terrain tiles."
        case .cycle: return "CyclOSM's cycle routes and lanes. Online only."
        case .downloaded: return "Outlines of the areas saved for offline use."
        }
    }

    var systemImage: String {
        switch self {
        case .topo: return "map"
        case .satellite: return "globe.europe.africa.fill"
        case .hillshade: return "mountain.2"
        case .cycle: return "bicycle"
        case .downloaded: return "arrow.down.circle"
        }
    }

    /// Credits for the attribution bar.
    var credit: String? {
        switch self {
        case .topo: return MapLayerCatalog.ignTopoCredit
        case .satellite: return MapLayerCatalog.ignSatelliteCredit
        case .hillshade: return MapLayerCatalog.terrainCredit
        case .cycle: return MapLayerCatalog.cycleCredit
        case .downloaded: return nil
        }
    }
}

/// What the MapLibre map shows, remembered in `@AppStorage("sh2.map.layers")` as JSON. Not `Codable`
/// itself: a `RawRepresentable` that is would encode as its raw value, which is this JSON.
struct MapLayerSelection: Equatable, RawRepresentable {
    /// The `@AppStorage` key, shared by every screen with a MapLibre map.
    static let storageKey = "sh2.map.layers"

    /// What is stored right now (for code outside a view, such as the library saving a route).
    static var stored: MapLayerSelection {
        UserDefaults.standard.string(forKey: storageKey).flatMap(MapLayerSelection.init(rawValue:)) ?? MapLayerSelection()
    }

    /// A file that exists only while a selection is being put on a map (`HaloMapView`). A file, not a
    /// default: it is on disk before the next line runs, even if that line stops the app.
    static var applyingMarker: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sh2-map-layers-applying")
    }

    /// At launch, before any map: the marker still there means the last run stopped while putting the
    /// overlays on the map. They are turned off, so the Map tab can open again, and the log says why.
    static func recoverFromInterruptedApply() {
        let marker = applyingMarker
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)
        let selection = stored
        guard !selection.overlays.isEmpty else { return }
        UserDefaults.standard.set(MapLayerSelection(base: selection.base).rawValue, forKey: storageKey)
        LogStore.shared.appendFromAnywhere("MapLibre: the app stopped while drawing the map's layers; they were turned off")
    }

    var base: MapBaseStyle = .night
    var overlays: Set<MapOverlay> = []

    init(base: MapBaseStyle = .night, overlays: Set<MapOverlay> = []) {
        self.base = base
        self.overlays = overlays
    }

    private struct Stored: Codable {
        var base: MapBaseStyle
        var overlays: [MapOverlay]
    }

    /// Turn an overlay on or off; a ground overlay replaces the other ground one.
    mutating func toggle(_ overlay: MapOverlay) {
        if overlays.contains(overlay) {
            overlays.remove(overlay)
        } else {
            if overlay.isGround { overlays = overlays.filter { !$0.isGround } }
            overlays.insert(overlay)
        }
    }

    /// Every credit the map owes right now, the base's first.
    var credits: [String] {
        var out = [MapLayerCatalog.osmCredit, MapLayerCatalog.openFreeMapCredit]
        for o in MapOverlay.allCases where overlays.contains(o) {
            if let c = o.credit { out.append(c) }
        }
        out.append(MapLayerCatalog.mapLibreCredit)
        return out
    }

    // RawRepresentable (JSON), so `@AppStorage` can hold it.
    var rawValue: String {
        let stored = Stored(base: base, overlays: MapOverlay.allCases.filter { overlays.contains($0) })
        return (try? JSONEncoder().encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        self.init(base: stored.base, overlays: Set(stored.overlays))
    }
}
