import SwiftUI
import MapKit
import QuartzCore

/// Drives the Navigating map at display rate so it glides instead of hopping from fix to fix:
/// between GPS fixes the rider is dead-reckoned along their course, corrections are eased in, and
/// the camera and the rider marker ease toward their targets (the `tau…` time constants).
///
/// Direction (Compass mode is hybrid): the GPS course while moving, the iPhone compass when slow
/// or stopped (turning the bike at a junction turns the map), and the course / route direction when
/// the compass is unreliable (`compassUnreliable` → a pill on screen). North and Free use the same
/// direction for the rider's beam; Free leaves the camera to the rider's fingers (`paused`).
@MainActor
final class FollowCamera: NSObject, ObservableObject {
    /// Eased rider position and direction (0 = north), for the marker.
    @Published private(set) var rider: CLLocationCoordinate2D?
    @Published private(set) var riderHeading: Double = 0
    /// What the map should show; not updated while `paused` or in Free.
    @Published private(set) var camera: MapCamera?
    /// Half-width of the rider's beam, degrees: narrow on the GPS course, wide on a doubtful compass.
    @Published private(set) var beamSpread: Double = 20
    @Published private(set) var compassUnreliable = false

    var orientation: MapOrientation = .compass
    var distance: Double = 600
    /// True while the rider's fingers move the map: the camera stays where they put it.
    var paused = false
    /// Current camera heading (what the follow camera is showing / easing to).
    var cameraHeading: Double { camHeading }

    /// Made on `start()`, so the view can create this object off the main actor (`@State`).
    private var compass: HeadingTracker?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?

    private var fix: CLLocation?
    private var fixSpeed: Double = 0
    private var course: Double = 0
    private var moving = false
    // Eased state, advanced every frame; the @Published copies only change when it really moved,
    // so a stopped rider doesn't redraw the map 60 times a second.
    private var pos: CLLocationCoordinate2D?
    private var posHeading: Double = 0
    private var camCenter: CLLocationCoordinate2D?
    private var camHeading: Double = 0

    /// Seconds to cover ~63 % of the gap to the target.
    private let tauRider = 0.25
    private let tauCenter = 0.12
    private let tauHeading = 0.45
    private let tauRiderHeading = 0.25
    /// Moving above this (m/s) uses the GPS course; below `stopBelow` the compass (hysteresis).
    private let moveAbove = 1.8
    private let stopBelow = 1.2
    /// Don't dead-reckon further than this past the last fix (lost GPS shouldn't run off).
    private let maxAhead: TimeInterval = 2
    /// A jump larger than this (metres) is a new place, not a correction: snap.
    private let snapBeyond: CLLocationDistance = 150

    nonisolated override init() { super.init() }

    func start() {
        let compass = self.compass ?? HeadingTracker()
        self.compass = compass
        compass.start()
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTick = nil
        compass?.stop()
    }

    /// A new location fix. `speed` in m/s, `course` = direction of travel (degrees).
    func update(fix: CLLocation, speed: Double?, course: Double) {
        self.fix = fix
        fixSpeed = max(0, speed ?? 0)
        self.course = course
        moving = fixSpeed > (moving ? stopBelow : moveAbove)
        if pos == nil {
            pos = fix.coordinate
            posHeading = course
        }
    }

    /// Resume following from wherever the map is now (after a zoom, or leaving Free): the camera
    /// eases back onto the rider instead of jumping.
    func resume(from live: MapCamera?) {
        resume(center: live?.centerCoordinate, heading: live?.heading)
    }

    /// The same, from a camera that isn't MapKit's (the MapLibre map).
    func resume(center: CLLocationCoordinate2D?, heading: Double?) {
        if let center { camCenter = center }
        if let heading { camHeading = heading }
        paused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(0.1, now - (lastTick ?? now))
        lastTick = now
        guard let fix else { return }
        func ease(_ tau: Double) -> Double { 1 - exp(-dt / tau) }

        // Position: dead-reckon from the last fix, then ease the marker onto it.
        let ahead = min(maxAhead, max(0, Date().timeIntervalSince(fix.timestamp)))
        let target = moving ? Geo.offset(fix.coordinate, distance: fixSpeed * ahead, bearing: course)
                            : fix.coordinate
        let r = pos.map { Geo.distance($0, target) < snapBeyond ? Self.lerp($0, target, ease(tauRider)) : target }
            ?? target
        pos = r
        if rider.map({ Geo.distance($0, r) > 0.02 }) ?? true { rider = r }

        // Direction: GPS course while moving, compass when slow — unless the compass is doubtful.
        let reading = compass?.heading
        let reliable = compass?.isReliable ?? false
        let useCompass = !moving && reliable
        let direction = useCompass ? (reading ?? course) : course
        let unreliable = !moving && reading != nil && !reliable
        if unreliable != compassUnreliable { compassUnreliable = unreliable }
        let spread: Double = moving ? 20 : useCompass ? min(45, max(20, compass?.accuracy ?? 20)) : 55
        if abs(spread - beamSpread) > 2 { beamSpread = spread }
        posHeading = Self.easeAngle(posHeading, to: direction, ease(tauRiderHeading))
        if abs(Geo.angleDelta(from: riderHeading, to: posHeading)) > 0.1 { riderHeading = posHeading }

        // Camera: centred on the rider, turned per mode.
        guard !paused, orientation != .free else { return }
        let c = camCenter.map { Geo.distance($0, r) < snapBeyond * 10 ? Self.lerp($0, r, ease(tauCenter)) : r } ?? r
        camCenter = c
        camHeading = Self.easeAngle(camHeading, to: orientation == .north ? 0 : direction, ease(tauHeading))
        if let cam = camera, Geo.distance(cam.centerCoordinate, c) < 0.02,
           abs(Geo.angleDelta(from: cam.heading, to: camHeading)) < 0.1, cam.distance == distance { return }
        camera = MapCamera(centerCoordinate: c, distance: distance, heading: camHeading, pitch: 0)
    }

    private static func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Ease an angle the short way round, kept in 0…360.
    private static func easeAngle(_ a: Double, to b: Double, _ t: Double) -> Double {
        let v = (a + Geo.angleDelta(from: a, to: b) * t).truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }
}
