import Foundation
import SwiftData
import MapKit
import UIKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import SH2Protocol

extension UTType {
    /// GPX (declared in Info.plist `UTImportedTypeDeclarations`, conforms to public.xml).
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// The routes library (UX_DESIGN §4.4, APP_SPEC M9): imported GPX files + their metadata.
///
/// - Metadata in SwiftData (`SavedRoute`, `container` — attach it with `.modelContainer(…)` and use
///   `@Query` in views); GPX bytes in Application Support/Routes/<uuid>.gpx.
/// - `importGPX(from:defaultSource:)` is the single entry point for Files, "Open in…" and the Map
///   tab; duplicates (same bytes) return the existing route.
/// - `route(for:)` rebuilds the `GPXRoute` with the saved route's id (stable identity across
///   launches); `select(_:navigate:)` hands it to `RouteSelection` and marks it used.
/// - `pendingDetail`: set after an "Open in…" import; the Routes tab pushes that route's detail.
@MainActor
final class RouteLibrary: ObservableObject {
    static let shared = RouteLibrary()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Route to open in the Routes tab (consumed and reset by `RoutesTab`).
    @Published var pendingDetail: UUID?
    /// True while nothing has been imported yet (the Map tab's first-run hint). Kept up to date by
    /// the imports and deletions, so reading it in a view body costs no fetch.
    @Published private(set) var isEmpty = true

    private var routeCache: [UUID: GPXRoute] = [:]
    private var imageCache: [UUID: (size: Int, image: UIImage)] = [:]
    private var thumbsInFlight: Set<UUID> = []
    private var thumbsFailed: Set<UUID> = []

    private init() {
        do {
            container = try ModelContainer(for: SavedRoute.self)
        } catch {
            LogStore.shared.appendFromAnywhere("Routes: persistent store unavailable (\(error)); using memory.")
            // swiftlint:disable:next force_try
            container = try! ModelContainer(for: SavedRoute.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        refreshIsEmpty()
    }

    // MARK: - Files

    /// Application Support/Routes (created on first use, excluded from nothing — backed up).
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func fileURL(for saved: SavedRoute) -> URL {
        Self.directory.appendingPathComponent(saved.fileName)
    }

    /// The app's visible name (for "Share › rehalo" hints).
    nonisolated static var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "rehalo"
    }

    // MARK: - Import
    //
    // The file read (security-scoped, and coordinated, which waits for an iCloud download), the
    // SHA-256 and the GPX parse run off the main actor (`prepare`); only the SwiftData side runs
    // on it (`store`). `importsInFlight` lets the Routes and Map tabs show progress meanwhile.

    /// Imports being read, parsed or stored right now.
    @Published private(set) var importsInFlight = 0
    var isImporting: Bool { importsInFlight > 0 }

    /// A GPX read, hashed and parsed, ready to be stored.
    struct PreparedImport: Sendable {
        let data: Data
        let hash: String
        let route: GPXRoute
        let fallbackName: String
        let source: RouteSource
    }

    /// Import a GPX from a file URL (Files picker, "Open in…", AirDrop). Removes the system's
    /// Inbox copy afterwards. The source is sniffed from the GPX header (Wikiloc, Komoot…), else
    /// `defaultSource`.
    @discardableResult
    func importGPX(from url: URL, defaultSource: RouteSource) async throws -> SavedRoute {
        importsInFlight += 1
        defer { importsInFlight -= 1 }
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepare(url: url, defaultSource: defaultSource)
        }.value
        return try await store(prepared, name: nil)
    }

    /// Import GPX bytes. `name` overrides the GPX `<name>` (used for the localized demo name).
    /// `steps`: a routed destination's typed steps, kept next to the GPX so riding the saved route
    /// again has its manoeuvres (docs/APP_SPEC.md M17).
    @discardableResult
    func importGPX(data: Data, fallbackName: String, source: RouteSource, name: String? = nil,
                   steps: [RoutedStep] = []) async throws -> SavedRoute {
        importsInFlight += 1
        defer { importsInFlight -= 1 }
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepare(data: data, fallbackName: fallbackName, source: source)
        }.value
        return try await store(prepared, name: name, steps: steps)
    }

    /// Add (or find) the bundled demo route "Demo route · City centre". Nil if the app has no
    /// bundled `DemoRoute.gpx`.
    @discardableResult
    func addDemoRoute() async -> SavedRoute? {
        let demoRaw = RouteSource.demo.rawValue
        if let existing = fetchOne(#Predicate<SavedRoute> { $0.sourceRaw == demoRaw }) { return existing }
        guard let url = Bundle.main.url(forResource: "DemoRoute", withExtension: "gpx"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? await importGPX(data: data, fallbackName: "DemoRoute", source: .demo,
                                    name: String(localized: "Demo route · City centre"))
    }

    /// Off the main actor: the security-scoped, coordinated read, then `prepare(data:…)`.
    nonisolated private static func prepare(url: URL, defaultSource: RouteSource) throws -> PreparedImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var readError: Error?
        var read: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { u in
            do { read = try Data(contentsOf: u) } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let data = read else { throw GPXError.noPoints }

        let prepared = try prepare(data: data, fallbackName: url.deletingPathExtension().lastPathComponent,
                                   source: RouteSource.detect(in: data) ?? defaultSource)
        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return prepared
    }

    /// Off the main actor: hash and parse.
    nonisolated private static func prepare(data: Data, fallbackName: String, source: RouteSource) throws -> PreparedImport {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let parsed = try GPXDocumentParser().parse(data: data)
        guard parsed.points.count >= 2 else { throw GPXError.noPoints }
        return PreparedImport(data: data, hash: hash, route: parsed, fallbackName: fallbackName, source: source)
    }

    /// On the main actor: dedupe by hash, write the file (off it), insert the metadata.
    private func store(_ prepared: PreparedImport, name: String?, steps: [RoutedStep] = []) async throws -> SavedRoute {
        let hash = prepared.hash
        if let existing = fetchOne(#Predicate<SavedRoute> { $0.contentHash == hash }) { return existing }

        let id = UUID()
        let fileName = id.uuidString + ".gpx"
        let fileURL = Self.directory.appendingPathComponent(fileName)
        let data = prepared.data
        try await Task.detached(priority: .userInitiated) { try data.write(to: fileURL, options: .atomic) }.value
        // The same bytes may have been imported while the file was being written.
        if let existing = fetchOne(#Predicate<SavedRoute> { $0.contentHash == hash }) {
            try? FileManager.default.removeItem(at: fileURL)
            return existing
        }
        if !steps.isEmpty, let encoded = try? JSONEncoder().encode(steps) {
            try? encoded.write(to: Self.stepsURL(forFileName: fileName), options: .atomic)
        }

        let parsed = prepared.route
        let parsedName = parsed.name == "Route" && !prepared.fallbackName.isEmpty ? prepared.fallbackName : parsed.name
        let displayName = name ?? parsedName
        let route = GPXRoute(id: id, name: displayName, points: parsed.points, elevations: parsed.elevations,
                             navPoints: parsed.navPoints)
        let saved = SavedRoute(id: id, name: displayName, source: prepared.source,
                               distance: route.length, gain: route.totalGain, loss: route.totalLoss,
                               estimatedDuration: route.estimatedDuration,
                               fileName: fileName, contentHash: hash)
        context.insert(saved)
        save()
        isEmpty = false
        routeCache[id] = route
        Task { await ensureThumbnail(for: saved) }
        // The map of its corridor, for the MapLibre engine when the rider wants it (M17).
        OfflineMapStore.shared.downloadIfWanted(route: route, name: displayName, style: MapLayerSelection.stored.base)
        return saved
    }

    // MARK: - Typed steps (routed destinations)

    /// The typed steps saved next to a route's GPX (`<uuid>.steps.json`); empty for a plain GPX.
    func routedSteps(for saved: SavedRoute) -> [RoutedStep] {
        guard let data = try? Data(contentsOf: Self.stepsURL(forFileName: saved.fileName)),
              let steps = try? JSONDecoder().decode([RoutedStep].self, from: data) else { return [] }
        return steps
    }

    static func stepsURL(forFileName fileName: String) -> URL {
        directory.appendingPathComponent((fileName as NSString).deletingPathExtension + ".steps.json")
    }

    // MARK: - Queries

    func savedRoute(id: UUID) -> SavedRoute? {
        fetchOne(#Predicate<SavedRoute> { $0.id == id })
    }

    /// The route's geometry, with `id == saved.id` and the saved (possibly renamed) name.
    func route(for saved: SavedRoute) -> GPXRoute? {
        if let cached = routeCache[saved.id] {
            if cached.name == saved.name { return cached }
            let renamed = GPXRoute(id: saved.id, name: saved.name, points: cached.points, elevations: cached.elevations,
                                   navPoints: cached.navPoints)
            routeCache[saved.id] = renamed
            return renamed
        }
        guard let data = try? Data(contentsOf: fileURL(for: saved)),
              let parsed = try? GPXDocumentParser().parse(data: data) else { return nil }
        let route = GPXRoute(id: saved.id, name: saved.name, points: parsed.points, elevations: parsed.elevations,
                             navPoints: parsed.navPoints)
        routeCache[saved.id] = route
        return route
    }

    // MARK: - Edits

    func rename(_ saved: SavedRoute, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != saved.name else { return }
        saved.name = trimmed
        save()
        let selection = RouteSelection.shared
        if selection.route?.id == saved.id, let route = route(for: saved) {
            selection.select(route, subtitle: selection.subtitle)
        }
    }

    func delete(_ saved: SavedRoute) {
        let id = saved.id
        try? FileManager.default.removeItem(at: fileURL(for: saved))
        try? FileManager.default.removeItem(at: Self.stepsURL(forFileName: saved.fileName))
        routeCache[id] = nil
        imageCache[id] = nil
        if RouteSelection.shared.route?.id == id { RouteSelection.shared.clear() }
        context.delete(saved)
        save()
        refreshIsEmpty()
    }

    func markUsed(_ saved: SavedRoute) {
        let now = Date()
        saved.lastUsedAt = now
        saved.lastActivity = now
        save()
    }

    /// Mark the library route with this id as used (no-op for routes not in the library).
    func markUsed(id: UUID) {
        if let saved = savedRoute(id: id) { markUsed(saved) }
    }

    /// Select `saved` on the Map tab (and start Navigating with `navigate: true`). Returns false if
    /// its GPX can't be read.
    @discardableResult
    func select(_ saved: SavedRoute, navigate: Bool = false) -> Bool {
        guard let route = route(for: saved) else { return false }
        markUsed(saved)
        RouteSelection.shared.select(route, subtitle: saved.sourceLabel, steps: routedSteps(for: saved), navigate: navigate)
        return true
    }

    private func refreshIsEmpty() {
        isEmpty = ((try? context.fetchCount(FetchDescriptor<SavedRoute>())) ?? 0) == 0
    }

    // MARK: - Sharing

    /// A share item exporting the GPX as "<name>.gpx" (for `ShareLink`).
    func shareFile(for saved: SavedRoute) -> GPXShareFile {
        GPXShareFile(source: fileURL(for: saved), name: saved.name)
    }

    // MARK: - Thumbnails

    /// Decoded thumbnail (cached), nil until `ensureThumbnail` has produced one.
    func thumbnailImage(for saved: SavedRoute) -> UIImage? {
        guard let data = saved.thumbnail else { return nil }
        if let cached = imageCache[saved.id], cached.size == data.count { return cached.image }
        guard let image = UIImage(data: data) else { return nil }
        imageCache[saved.id] = (data.count, image)
        return image
    }

    /// Generate and store the dark map thumbnail if missing (once per route per launch on failure).
    func ensureThumbnail(for saved: SavedRoute) async {
        let id = saved.id
        guard saved.thumbnail == nil, !thumbsInFlight.contains(id), !thumbsFailed.contains(id),
              let route = route(for: saved) else { return }
        thumbsInFlight.insert(id)
        defer { thumbsInFlight.remove(id) }
        if let data = await Self.snapshot(route) {
            // The route may have been deleted meanwhile.
            guard savedRoute(id: id) != nil else { return }
            saved.thumbnail = data
            save()
        } else {
            thumbsFailed.insert(id)
        }
    }

    /// Dark, muted map snapshot of the route with the polyline drawn in accent (JPEG data), on the
    /// map engine of Settings: MapLibre's night style (`MapLibreSnapshot`) or MapKit's.
    static func snapshot(_ route: GPXRoute, side: CGFloat = 180) async -> Data? {
        guard route.points.count > 1 else { return nil }
        if AppSettings.shared.mapEngine == .mapLibre {
            return await MapLibreSnapshot.thumbnail(route, side: side, style: MapLayerSelection.stored.base)
        }
        let options = MKMapSnapshotter.Options()
        options.mapRect = squareRect(route.boundingMapRect(padding: 0.12))
        options.size = CGSize(width: side, height: side)
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = .dark
            traits.displayScale = 3
        }
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = config

        let snapshotter = MKMapSnapshotter(options: options)
        let coords = downsample(route.points, max: 400)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            snapshotter.start { snapshot, _ in
                _ = snapshotter   // keep the snapshotter alive until it completes
                guard let snapshot else { cont.resume(returning: nil); return }
                let base = snapshot.image
                let points = coords.map { snapshot.point(for: $0) }
                let format = UIGraphicsImageRendererFormat()
                format.scale = base.scale
                let image = UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
                    base.draw(at: .zero)
                    let path = UIBezierPath()
                    for (k, p) in points.enumerated() {
                        if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.lineJoinStyle = .round
                    path.lineCapStyle = .round
                    UIColor(Theme.accent).withAlphaComponent(0.25).setStroke()
                    path.lineWidth = 9
                    path.stroke()
                    UIColor(Theme.accent).setStroke()
                    path.lineWidth = 3.5
                    path.stroke()
                }
                cont.resume(returning: image.jpegData(compressionQuality: 0.82))
            }
        }
    }

    private static func squareRect(_ r: MKMapRect) -> MKMapRect {
        let side = max(r.size.width, r.size.height)
        return MKMapRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
    }

    private static func downsample<T>(_ items: [T], max: Int) -> [T] {
        guard items.count > max, max > 1 else { return items }
        let stride = Double(items.count - 1) / Double(max - 1)
        return (0..<max).map { items[Int((Double($0) * stride).rounded())] }
    }

    // MARK: - Helpers

    private func fetchOne(_ predicate: Predicate<SavedRoute>) -> SavedRoute? {
        var descriptor = FetchDescriptor<SavedRoute>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func save() {
        do { try context.save() } catch {
            LogStore.shared.appendFromAnywhere("Routes: save failed: \(error)")
        }
    }
}

/// `ShareLink` item for a library route: exports a copy named after the route (`<name>.gpx`)
/// instead of the internal `<uuid>.gpx`.
struct GPXShareFile: Transferable {
    let source: URL
    let name: String

    var fileName: String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "route" : cleaned) + ".gpx"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gpx) { item in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(item.fileName)
            try FileManager.default.copyItem(at: item.source, to: dest)
            return SentTransferredFile(dest)
        }
    }
}
