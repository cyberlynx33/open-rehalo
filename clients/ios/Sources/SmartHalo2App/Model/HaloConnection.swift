import Foundation
import Combine
import CoreBluetooth
import SH2Protocol

/// The single, app-wide connection state shown by the global `StatusChip` (UX_DESIGN §3).
enum HaloConnectionState: Equatable {
    case connected       // session ready (handshake done)
    case connecting      // connecting / authenticating / reconnecting
    case disconnected    // no Halo, link down, Bluetooth off, or the ring is out of range
    case needsRecovery   // the ring holds a password this iPhone doesn't have: re-pair needed
}

/// Owns "my Halo": the one `DeviceController` the whole app shares (Mapa, Halo tab, Settings…).
///
/// - Persists the paired peripheral identifier in `AppSettings.myHaloID`.
/// - On launch (`bootstrap()`), waits for Bluetooth, `retrievePeripherals(withIdentifiers:)` and
///   issues a pending connect — CoreBluetooth completes it whenever the ring is in range.
/// - Auto-reconnects on an unexpected drop (and when Bluetooth comes back), with backoff on errors.
/// - Demo mode (`startDemo()`) swaps in the simulated ring (`MockTransport`); `isDemo` drives the
///   persistent DEMO badge.
@MainActor
final class HaloConnection: ObservableObject {
    static let shared = HaloConnection()

    /// Drives the StatusChip.
    @Published private(set) var state: HaloConnectionState = .disconnected
    /// The live controller for my Halo (or the demo ring). Nil = nothing paired / chosen yet.
    @Published private(set) var controller: DeviceController?
    /// Fires (main thread) when a pairing started with `pair(with:)` ends in `.needsRecovery`: the
    /// ring is paired with a password this iPhone doesn't have. `RootView` opens the recovery
    /// wizard (UX_DESIGN §4.7) — from the onboarding's pairing step or Settings › Pair another.
    let pairingNeedsRecovery = PassthroughSubject<Void, Never>()

    var isDemo: Bool { controller?.isDemo ?? false }
    /// True if a real Halo is saved (auto-connect target), even while it's out of range.
    var hasSavedHalo: Bool { settings.myHaloID != nil }
    /// Name to show for my Halo.
    var displayName: String? {
        guard let controller else { return settings.myHaloName }
        if !controller.deviceName.isEmpty { return controller.deviceName }   // renamed this session
        return controller.isDemo ? controller.device.name : (settings.myHaloName ?? controller.device.name)
    }

    private let central: BluetoothCentral
    private let settings: AppSettings
    private var bag = Set<AnyCancellable>()
    private var phaseSub: AnyCancellable?
    private var retryTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var stalled = false
    private var retryAttempt = 0
    /// Set when the user explicitly disconnected — suppresses auto-reconnect until `retry()`.
    private var userDisconnected = false
    private var bootstrapped = false
    /// True between `pair(with:)` and the first handshake outcome (see `pairingNeedsRecovery`).
    private var pairingPending = false

    /// How long a pending connect may show "Connecting…" before the chip falls back to "No Halo"
    /// (the pending connect itself stays armed and completes if the ring shows up later).
    private let stallAfter: Duration = .seconds(20)

    private init() {
        self.central = BluetoothCentral.shared
        self.settings = AppSettings.shared

        central.disconnects
            .sink { [weak self] event in self?.handleDisconnect(event) }
            .store(in: &bag)

        central.$state
            .removeDuplicates()
            .sink { [weak self] s in self?.handleCentralState(s) }
            .store(in: &bag)
    }

    // MARK: - Public API

    /// Call once at launch: resumes the demo, or auto-connects to the saved Halo when Bluetooth is on.
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        if settings.demoMode {
            startDemo()
        } else {
            Task { await autoConnect() }
        }
    }

    /// Make `device` "my Halo" (persisted) and connect to it. Used by the pairing step / ScanView.
    func pair(with device: DiscoveredDevice) {
        settings.demoMode = false
        settings.myHaloID = device.id
        settings.myHaloName = device.name
        userDisconnected = false
        pairingPending = true
        install(DeviceController(device: device, central: central))
        Task { await controller?.start() }
    }

    /// Switch to the simulated ring. Doesn't touch the saved Halo.
    func startDemo() {
        pairingPending = false
        settings.demoMode = true
        userDisconnected = false
        install(DeviceController(device: .demo, central: central, demoTransport: MockTransport()))
        Task { await controller?.start() }
    }

    /// Leave demo mode and go back to the saved Halo (if any).
    func stopDemo() {
        settings.demoMode = false
        install(nil)
        Task { await autoConnect() }
    }

    /// Chip "disconnected" tap / "Reconectar" buttons: try again right now.
    func retry() {
        userDisconnected = false
        retryAttempt = 0
        guard let controller else {
            Task { await autoConnect() }
            return
        }
        retryTask?.cancel()
        switch controller.phase {
        case .ready:
            return
        case .connecting, .authenticating:
            // A connect or a handshake is in flight: a second `start()` over it would ask
            // CoreBluetooth to connect a peripheral that already is, and could leave the ring
            // authenticated with the app stuck in "Connecting…". Begin again from a clean link.
            Task { await controller.restart() }
        default:
            Task { await controller.start() }
        }
    }

    /// User-initiated disconnect (no auto-reconnect until `retry()`).
    func disconnect() {
        userDisconnected = true
        retryTask?.cancel()
        guard let controller else { return }
        controller.close()
        controller.markDisconnected()
        recompute(controller.phase)
    }

    /// Forget my Halo (and leave demo mode). The device password stays in the Keychain so pairing
    /// the same ring again doesn't need a new recovery.
    func forget() {
        pairingPending = false
        settings.myHaloID = nil
        settings.myHaloName = nil
        settings.demoMode = false
        install(nil)
    }

    // MARK: - Internals

    private func autoConnect() async {
        guard controller == nil, !settings.demoMode, let id = settings.myHaloID else {
            recompute(controller?.phase)
            return
        }
        // A saved Halo is the reason to start Bluetooth (and, the first time, its permission
        // prompt); with none, the pairing step's scan starts it. Until it reports `.poweredOn`,
        // `handleCentralState()` brings us back here.
        central.activate()
        guard central.state == .poweredOn else { return }
        guard let device = await central.retrieveDevice(id: id, name: settings.myHaloName) else {
            SH2Log.log("connection: saved Halo \(id.uuidString.prefix(8)) not known to CoreBluetooth — pair again")
            recompute(nil)
            return
        }
        // Another path (pair / demo) may have installed a controller while we were awaiting.
        guard controller == nil, !settings.demoMode else { return }
        SH2Log.log("connection: auto-connecting to my Halo “\(device.name)”")
        install(DeviceController(device: device, central: central))
        await controller?.start()
    }

    /// Replace the current controller (closing the old one) and observe its phase.
    private func install(_ new: DeviceController?) {
        retryTask?.cancel()
        stallTask?.cancel()
        stalled = false
        retryAttempt = 0
        phaseSub = nil
        if let old = controller, old !== new { old.close() }
        controller = new
        if let new {
            phaseSub = new.$phase
                .removeDuplicates()
                .sink { [weak self] phase in self?.phaseChanged(phase) }
            phaseChanged(new.phase)
        } else {
            recompute(nil)
        }
    }

    private func phaseChanged(_ phase: DeviceController.Phase) {
        stallTask?.cancel()
        stalled = false
        if pairingPending {
            switch phase {
            case .needsRecovery:
                pairingPending = false
                pairingNeedsRecovery.send()
            case .ready:
                pairingPending = false
            default:
                break
            }
        }
        switch phase {
        case .connecting:
            let wait = stallAfter
            stallTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                self.stalled = true
                self.recompute(self.controller?.phase)
            }
        case .ready:
            retryAttempt = 0
        case .disconnected:
            scheduleReconnect()
        case .error:
            scheduleReconnect()
        default:
            break
        }
        recompute(phase)
    }

    private func recompute(_ phase: DeviceController.Phase?) {
        let new: HaloConnectionState
        switch phase {
        case .none:
            new = .disconnected
        case .some(.ready):
            new = .connected
        case .some(.connecting):
            new = stalled ? .disconnected : .connecting
        case .some(.authenticating), .some(.recovering):
            new = .connecting
        case .some(.needsRecovery), .some(.needsReboot):
            new = .needsRecovery
        case .some(.disconnected), .some(.error):
            new = .disconnected
        }
        if state != new { state = new }
    }

    private func handleDisconnect(_ event: BluetoothCentral.DisconnectEvent) {
        guard event.unexpected, let controller, !controller.isDemo,
              controller.device.id == event.id else { return }
        // Only a live session is ours to repair; drops during recovery are part of that flow
        // (the ring un-pairs and hangs up) and DeviceController handles them itself.
        if controller.phase == .ready {
            SH2Log.log("connection: Halo dropped unexpectedly — reconnecting")
            controller.markDisconnected()      // → phaseChanged(.disconnected) → scheduleReconnect
        }
    }

    private func handleCentralState(_ s: CBManagerState) {
        guard bootstrapped else { return }
        if s == .poweredOn {
            if controller == nil {
                Task { await autoConnect() }
            } else if state == .disconnected {
                scheduleReconnect(immediately: true)
            }
        }
    }

    /// Reconnect with backoff (0.5 s, 2 s, 5 s, 10 s, then every 30 s). Pending connects never time
    /// out in CoreBluetooth, so a single successful `start()` waits for the ring to come back.
    private func scheduleReconnect(immediately: Bool = false) {
        guard !userDisconnected, let controller, !controller.isDemo else { return }
        let delays: [Double] = [0.5, 2, 5, 10, 30]
        let delay = immediately ? 0.2 : delays[min(retryAttempt, delays.count - 1)]
        retryAttempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self, weak controller] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let controller,
                  self.controller === controller, !self.userDisconnected,
                  self.central.state == .poweredOn else { return }
            switch controller.phase {
            case .disconnected, .error: await controller.start()
            default: break
            }
        }
    }
}
