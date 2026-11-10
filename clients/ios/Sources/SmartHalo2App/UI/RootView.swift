import SwiftUI

/// Top-level view: onboarding on first run, otherwise the Map · Routes · Halo tab shell. Kicks off
/// the auto-connect to "my Halo" (or resumes the demo) once at launch, and hosts the recovery
/// wizard modal (`AppRouter.showRecovery`) over both.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: RouteLibrary

    @State private var openError: String?

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .haloTheme()
        .task {
            connection.bootstrap()
        }
        // "Open in… / Share › Halo" from Wikiloc, Komoot, Mail, Files, AirDrop (Info.plist declares
        // com.topografix.gpx): import into the library, then show it in Routes › detail.
        .onOpenURL { openURL($0) }
        .alert("Couldn't import the route", isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: openError ?? "")
        }
        .onChange(of: settings.hasCompletedOnboarding) { _, done in
            // Fresh from onboarding → the Map (first-run hint → search → demo route), UX_DESIGN §5.1.
            // A re-run from Settings › Connection mode left Settings pushed on the Halo tab: pop it,
            // or the next visit to Halo would land there instead of on the cards.
            guard done else { return }
            router.haloPath = []
            if library.pendingDetail == nil { router.tab = .map }
        }
        // Recovery wizard (UX_DESIGN §4.7): chip, Halo tab, Advanced, or a pairing that needs it.
        .fullScreenCover(isPresented: $router.showRecovery) {
            RecoveryWizard()
        }
        .onReceive(connection.pairingNeedsRecovery) { router.openRecovery() }
    }

    private func openURL(_ url: URL) {
        guard url.isFileURL else { return }
        do {
            let saved = try library.importGPX(from: url, defaultSource: .shared)
            router.tab = .routes
            library.pendingDetail = saved.id
        } catch {
            openError = String(localized: "Couldn't load GPX: \(error.localizedDescription)")
        }
    }
}

/// The main `TabView`. Map = M8 map-first screen, Routes = M9 library, Halo = M10 device tab
/// (Settings is pushed inside the Halo tab: `AppRouter.openSettings()`).
struct MainTabView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.tab) {
            // Full-screen map: floats its own DEMO badge + status chip (no chrome bar), and runs under
            // a see-through tab bar that it hides along with the rest of its controls.
            MapTab()
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .tabItem { Label("Map", systemImage: "map") }
                .tag(AppTab.map)

            RoutesTab()
                .haloChrome()
                .tabItem { Label("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(AppTab.routes)

            HaloTab()
                .haloChrome()
                .tabItem { Label("Halo", systemImage: "circle.circle") }
                .tag(AppTab.halo)
        }
    }
}
