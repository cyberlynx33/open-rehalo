import SwiftUI

/// The three main tabs (UX_DESIGN §3).
enum AppTab: Hashable {
    case map, routes, halo
}

/// Screens pushed on the Halo tab's `NavigationStack` (value-based, so a deep link can pop to root).
enum HaloRoute: Hashable {
    case settings, advanced
    case rename, pair
    case ringWidgets, display, fitness
    case soundTouch, liveLog
    case login, rides
    case offlineMaps
}

/// App-wide navigation state, so any screen (the chip, a route's "Navigate" button, a notification
/// deep link…) can switch tabs or open Settings.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var tab: AppTab = .map
    /// Navigation path of the Halo tab (Settings, Advanced, recovery… are pushed here).
    @Published var haloPath: [HaloRoute] = []
    /// The recovery wizard (UX_DESIGN §4.7), presented full screen by `RootView` over whatever is
    /// showing — tabs or onboarding.
    @Published var showRecovery = false

    private init() {}

    /// Halo tab › Settings (replaces the old Settings sheet).
    func openSettings() {
        tab = .halo
        haloPath = [.settings]
    }

    /// Halo tab at its root (alarm notification deep link, chip taps).
    func showHaloHome() {
        tab = .halo
        haloPath = []
    }

    /// Open the recovery wizard modal (chip, Halo tab "Re-pair", Advanced, a pairing that needs it).
    func openRecovery() {
        showRecovery = true
    }
}

/// Global chrome on every tab but Map: DEMO badge (left) + connection `StatusChip` (right), above
/// the tab's own navigation bar. The Map tab floats the same two over its full-screen map.
struct HaloChrome: ViewModifier {
    @EnvironmentObject private var connection: HaloConnection

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                if connection.isDemo { DemoBadge() }
                Spacer(minLength: 0)
                HaloStatusButton()
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 2)
            .background(Theme.bg)
        }
        .toolbarBackground(Theme.bg, for: .tabBar)
    }
}

/// The connection `StatusChip`, with UX_DESIGN §3's tap behaviour.
struct HaloStatusButton: View {
    var compact = false

    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        StatusChip(state: connection.state, compact: compact) { chipTapped() }
    }

    private func chipTapped() {
        switch connection.state {
        case .connected, .connecting:
            router.showHaloHome()
        case .disconnected:
            if connection.controller != nil || connection.hasSavedHalo {
                connection.retry()
            } else {
                router.showHaloHome()       // nothing paired yet → pairing (ScanView)
            }
        case .needsRecovery:
            router.openRecovery()           // recovery wizard (modal)
        }
    }
}

extension View {
    /// Adds the global DEMO badge + connection chip bar (see `HaloChrome`).
    func haloChrome() -> some View { modifier(HaloChrome()) }
}
