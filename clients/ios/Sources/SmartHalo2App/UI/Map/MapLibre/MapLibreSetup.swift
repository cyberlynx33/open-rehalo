import Foundation
import MapLibre

/// One-time MapLibre configuration, before the first `MLNMapView` (called from `SmartHalo2App.init`):
/// at most four connections per tile host (OpenFreeMap's terms for downloads) and a bigger ambient
/// cache, so tiles seen on a ride are there without a download. MapLibre's own User-Agent already
/// names this app (its bundle id and version), as OpenFreeMap asks.
enum MapLibreSetup {
    /// OpenFreeMap: "at most 4 parallel requests".
    static let maximumConnectionsPerHost = 4
    /// Ambient cache (tiles seen while browsing), bytes. MapLibre's default is 50 MB.
    static let ambientCacheBytes: UInt64 = 200 * 1024 * 1024

    private static var configured = false

    static func configure() {
        guard !configured else { return }
        configured = true
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        configuration.requestCachePolicy = .useProtocolCachePolicy
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(ambientCacheBytes) { error in
            if let error { LogStore.shared.appendFromAnywhere("MapLibre: ambient cache size: \(error)") }
        }
    }
}
