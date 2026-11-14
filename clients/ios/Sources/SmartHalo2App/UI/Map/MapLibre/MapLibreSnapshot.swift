import Foundation
import UIKit
import CoreLocation
import MapLibre

/// Route thumbnails on the MapLibre night style (`MLNMapSnapshotter`), the route drawn over the
/// snapshot as `RouteLibrary.snapshot` draws it over MapKit's. Needs the style and its tiles online
/// or in the offline cache.
enum MapLibreSnapshot {
    /// Padding round the route, as a share of its extent.
    static let padding = 0.12
    /// Points the route is thinned to before drawing.
    static let maximumPoints = 400

    @MainActor
    static func thumbnail(_ route: GPXRoute, side: CGFloat = 180, style: MapBaseStyle = .night) async -> Data? {
        guard route.points.count > 1, let bounds = padded(route.points) else { return nil }
        MapLibreSetup.configure()
        let camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: (bounds.sw.latitude + bounds.ne.latitude) / 2,
                                                                        longitude: (bounds.sw.longitude + bounds.ne.longitude) / 2),
                                  altitude: 1_000, pitch: 0, heading: 0)
        let options = MLNMapSnapshotOptions(styleURL: style.styleURL, camera: camera, size: CGSize(width: side, height: side))
        options.coordinateBounds = bounds
        options.scale = 3
        let snapshotter = MLNMapSnapshotter(options: options)
        let coords = downsample(route.points, max: maximumPoints)
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

    /// A square box round the points with `padding` on each side.
    static func padded(_ points: [CLLocationCoordinate2D]) -> MLNCoordinateBounds? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in points {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let midLat = (minLat + maxLat) / 2, midLon = (minLon + maxLon) / 2
        let k = max(0.01, cos(midLat * .pi / 180))
        // Square in metres, at least 400 m across, padded.
        let side = max(400.0 / 111_320, max(maxLat - minLat, (maxLon - minLon) * k)) * (1 + 2 * padding)
        return MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: midLat - side / 2, longitude: midLon - side / 2 / k),
                                   ne: CLLocationCoordinate2D(latitude: midLat + side / 2, longitude: midLon + side / 2 / k))
    }

    static func downsample<T>(_ items: [T], max: Int) -> [T] {
        guard items.count > max, max > 1 else { return items }
        let stride = Double(items.count - 1) / Double(max - 1)
        return (0..<max).map { items[Int((Double($0) * stride).rounded())] }
    }
}
