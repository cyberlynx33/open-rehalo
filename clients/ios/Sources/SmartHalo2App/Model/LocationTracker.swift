import Foundation
import CoreLocation

/// Thin CoreLocation wrapper. Delivers updates via callbacks on the main actor so the owning
/// `GuidanceController` can stay `@MainActor` without worrying about delegate threading.
@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onAuth: ((CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()
    /// The newest fix delivered: a batch that arrives late (deferred updates, or two batches whose
    /// tasks ran out of order) must not take the ride back in time.
    private var lastTimestamp: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Every fix, like the official app (fused provider, 1 s, no minimum displacement): its ring
        // guidance estimates the direction of travel from consecutive fixes.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ask for When-In-Use permission (no-op if already decided).
    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Ask once for *Always* (UX_DESIGN §4.1: on the first navigation that went to the background).
    /// Only escalates an existing When-In-Use grant, and only the first time — iOS shows that
    /// prompt a single time anyway. Background guidance keeps working with When-In-Use.
    func requestAlwaysOnce() {
        let key = "sh2.location.askedAlways"
        guard manager.authorizationStatus == .authorizedWhenInUse,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        manager.requestAlwaysAuthorization()
    }

    /// Start updates. `background: true` keeps them flowing with the phone locked / app in the
    /// background while navigating (needs the `location` UIBackgroundMode, declared in Info.plist;
    /// When-In-Use is enough — iOS shows the blue location indicator).
    func start(background: Bool = false) {
        requestAuthorization()
        lastTimestamp = nil
        if background {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }
        // Every fix of the batch, in order: a batch holds several after a pause (deferred updates),
        // and the ride logic reads each one at 1 Hz, so only the last would lose the ones before.
        Task { @MainActor in self.deliver(locations) }
    }

    private func deliver(_ locations: [CLLocation]) {
        for loc in locations {
            if let last = lastTimestamp, loc.timestamp <= last { continue }
            lastTimestamp = loc.timestamp
            onLocation?(loc)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.onAuth?(status) }
    }
}
