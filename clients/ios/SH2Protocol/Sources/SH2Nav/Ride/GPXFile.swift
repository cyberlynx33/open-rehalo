import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum GPXError: Error, LocalizedError {
    case noPoints
    /// The XML itself couldn't be read; the parser's own account of the fault, when it gives one.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .noPoints: "No track points found in the GPX file."
        case .malformed(let detail):
            detail.isEmpty ? "The GPX file isn't well-formed XML." : "The GPX file isn't well-formed XML: \(detail)"
        }
    }
}

/// The route in a GPX file, as both the screen and the ring follow it.
public struct GPXFile: Equatable, Sendable {
    public let name: String
    /// The route: its `<trkpt>`s, or its `<wpt>`s when there are more of them (what the official app
    /// navigates), or else its `<rtept>`s, which the official app couldn't navigate at all. They never
    /// mix: a track's points of interest or a planned `<rte>` next to it are not part of the route.
    public let points: [GeoPoint]
    /// Elevation per point in `points`.
    public let elevations: [Double?]
    public var navPoints: [GeoPoint] { points }

    /// Minimal GPX parser — extracts the `<trkpt>`s, `<rtept>`s and `<wpt>`s (lat/lon + optional
    /// `<ele>`), and the route's `<name>`: the track's (or planned route's), else the file's
    /// (`<metadata>`), else the first of any other. Mirrors the fields used by the official app's
    /// `GPXParser`.
    public static func parse(data: Data) throws -> GPXFile {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Local names: a GPX that prefixes its elements (`<gpx:trkpt>`) is read like any other.
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw GPXError.malformed(parser.parserError?.localizedDescription ?? "") }
        let main = delegate.waypoints.count > delegate.track.count ? delegate.waypoints : delegate.track
        let route = main.isEmpty ? delegate.planned : main
        guard !route.isEmpty else { throw GPXError.noPoints }
        return GPXFile(name: delegate.name.isEmpty ? "Route" : delegate.name, points: route.map(\.point),
                       elevations: route.map(\.elevation))
    }

    private struct Point {
        var point: GeoPoint
        var elevation: Double?
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var track: [Point] = []
        var waypoints: [Point] = []
        var planned: [Point] = []
        var name = ""
        private var current: ReferenceWritableKeyPath<Delegate, [Point]>?
        /// The open elements, outermost first: whose `<name>` a name is.
        private var path: [String] = []
        /// How good the name kept is (lower is better; the first of a rank wins): the track's or
        /// planned route's, then the file's (`<metadata>`), then anyone else's — a waypoint's, the
        /// author's, a link's — which used to win just by coming first.
        private var nameRank = Int.max
        private var pendingRank = Int.max
        private var inName = false
        private var nameBuf = ""
        private var inEle = false
        private var eleBuf = ""

        static func rank(ofNameIn parent: String) -> Int {
            switch parent {
            case "trk": 0
            case "rte": 1
            case "metadata": 2
            default: 3
            }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let element = elementName.lowercased()
            let parent = path.last ?? ""
            path.append(element)
            switch element {
            case "trkpt", "rtept", "wpt":
                if let latS = attributeDict["lat"], let lonS = attributeDict["lon"],
                   let lat = Double(latS), let lon = Double(lonS) {
                    let list: ReferenceWritableKeyPath<Delegate, [Point]> =
                        element == "wpt" ? \.waypoints : element == "trkpt" ? \.track : \.planned
                    self[keyPath: list].append(Point(point: GeoPoint(lat, lon)))
                    current = list
                }
            case "ele" where current != nil:
                inEle = true; eleBuf = ""
            case "name":
                let rank = Self.rank(ofNameIn: parent)
                if rank < nameRank { inName = true; nameBuf = ""; pendingRank = rank }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inName { nameBuf += string }
            if inEle { eleBuf += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if !path.isEmpty { path.removeLast() }
            switch elementName.lowercased() {
            case "name" where inName:
                let trimmed = nameBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { name = trimmed; nameRank = pendingRank }
                inName = false
            case "ele" where inEle:
                if let e = Double(eleBuf.trimmingCharacters(in: .whitespacesAndNewlines)), let list = current,
                   let last = self[keyPath: list].indices.last {
                    self[keyPath: list][last].elevation = e
                }
                inEle = false
            case "trkpt", "rtept", "wpt":
                current = nil
            default: break
            }
        }
    }
}
