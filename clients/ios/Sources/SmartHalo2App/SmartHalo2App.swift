import SwiftUI
import SH2Protocol

/// App entry point. Pure SwiftUI App lifecycle (no AppDelegate/SceneDelegate needed).
@main
struct SmartHalo2App: App {
    @StateObject private var central = BluetoothCentral.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var auth = AuthStore.shared
    @StateObject private var connection = HaloConnection.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var guidance = GuidanceController.shared
    @StateObject private var selection = RouteSelection.shared
    @StateObject private var library = RouteLibrary.shared
    /// Launch motion (boot sweep) over the app, once per cold launch.
    @State private var showLaunch = true

    init() {
        // Bridge the protocol layer's log lines into the in-app live console.
        SH2Log.setSink { line in LogStore.shared.appendFromAnywhere(line) }
        // A MapLibre overlay that stopped the app last time is off before the Map tab draws it again.
        MapLayerSelection.recoverFromInterruptedApply()
        // Alarm notifications: become the UNUserNotificationCenter delegate before launch finishes,
        // so tapping a notification that cold-launches the app still opens the Halo tab.
        MainActor.assumeIsolated {
            AlarmNotifier.shared.activate()
            // Navigation Live Activity / Dynamic Island (M12): follows GuidanceController.shared.
            LiveActivityManager.shared.activate()
            CallAlertController.shared.activate()
            RainAlertController.shared.activate()
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(central)
                    .environmentObject(settings)
                    .environmentObject(auth)
                    .environmentObject(connection)
                    .environmentObject(router)
                    .environmentObject(guidance)
                    .environmentObject(selection)
                    .environmentObject(library)
                    .modelContainer(RouteLibrary.shared.container)
                if showLaunch {
                    LaunchSweepOverlay { showLaunch = false }
                }
            }
        }
    }
}
