import Foundation
import SwiftData

/// Where a saved route came from, shown under its name ("Wikiloc", "Files", "Included"…).
enum RouteSource: String, CaseIterable {
    case files
    case shared          // "Open in…" / share sheet from an app we couldn't identify
    case demo            // the bundled DemoRoute.gpx
    case appleMaps = "applemaps"   // a destination routed by Apple Maps, saved from the Map tab
    case brouter                   // a destination routed by the rider's BRouter server
    case wikiloc, komoot, strava, garmin
    case rideWithGPS = "ridewithgps"

    var label: String {
        switch self {
        case .files: return String(localized: "Files")
        case .shared: return String(localized: "Shared")
        case .demo: return String(localized: "Included")
        case .appleMaps: return "Apple Maps"
        case .brouter: return "BRouter"
        case .wikiloc: return "Wikiloc"
        case .komoot: return "Komoot"
        case .strava: return "Strava"
        case .garmin: return "Garmin"
        case .rideWithGPS: return "Ride with GPS"
        }
    }

    /// Best-effort guess from the GPX header (`creator="…"`, metadata links): exporters name
    /// themselves there. Nil when nothing recognisable is found.
    static func detect(in data: Data) -> RouteSource? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if head.contains("wikiloc") { return .wikiloc }
        if head.contains("komoot") { return .komoot }
        if head.contains("strava") { return .strava }
        if head.contains("ridewithgps") || head.contains("ride with gps") { return .rideWithGPS }
        if head.contains("garmin") { return .garmin }
        return nil
    }
}

/// A route in the library (UX_DESIGN §4.4), persisted with SwiftData. The GPX itself lives in
/// Application Support/Routes/`fileName`; the stats are cached here so the list never parses GPX.
/// Load the geometry with `RouteLibrary.route(for:)` (a `GPXRoute` whose `id` == `id`).
@Model
final class SavedRoute {
    @Attribute(.unique) var id: UUID
    var name: String
    /// `RouteSource.rawValue` (kept as a string so new sources don't need a migration).
    var sourceRaw: String
    /// Metres.
    var distance: Double
    /// Metres of climb / descent (nil when the GPX has no `<ele>`).
    var gain: Double?
    var loss: Double?
    /// Seconds (`GPXRoute.estimatedDuration`).
    var estimatedDuration: Double
    var createdAt: Date
    var lastUsedAt: Date?
    /// `lastUsedAt ?? createdAt` — the list's sort key ("last used first", new imports on top).
    var lastActivity: Date
    /// File name inside `RouteLibrary.directory`.
    var fileName: String
    /// SHA-256 of the GPX bytes: importing the same file twice returns the existing route.
    var contentHash: String
    /// Cached dark `MKMapSnapshotter` thumbnail (JPEG), generated lazily.
    @Attribute(.externalStorage) var thumbnail: Data?

    init(id: UUID = UUID(),
         name: String,
         source: RouteSource,
         distance: Double,
         gain: Double?,
         loss: Double?,
         estimatedDuration: Double,
         fileName: String,
         contentHash: String,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sourceRaw = source.rawValue
        self.distance = distance
        self.gain = gain
        self.loss = loss
        self.estimatedDuration = estimatedDuration
        self.createdAt = createdAt
        self.lastUsedAt = nil
        self.lastActivity = createdAt
        self.fileName = fileName
        self.contentHash = contentHash
        self.thumbnail = nil
    }

    var source: RouteSource? { RouteSource(rawValue: sourceRaw) }
    var sourceLabel: String { source?.label ?? sourceRaw }
    var isDemo: Bool { sourceRaw == RouteSource.demo.rawValue }
}
