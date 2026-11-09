import SwiftUI
import SH2Protocol

/// Recovery wizard (UX_DESIGN §4.7): a full-screen modal, presented by `RootView` whenever
/// `AppRouter.showRecovery` is set — the chip in "needs re-pair", the Halo tab's "Re-pair",
/// Settings › Advanced, or a pairing whose handshake ended in `.needsRecovery`.
///
/// Three steps over the existing `DeviceController` API:
/// 1. explain → `recover()` (reset-challenge + re-pair; progress, errors with retry);
/// 2. `.needsReboot`: power-cycle the ring once. `RebootWatcher` notices the ring disappearing and
///    coming back and calls `reconnectAndFinish()` by itself; "I've rebooted it" is the fallback;
/// 3. `.ready`: done. The new password isn't shown here (Settings › Advanced keeps it).
struct RecoveryWizard: View {
    @EnvironmentObject private var connection: HaloConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller = connection.controller {
                RecoveryWizardContent(controller: controller) { dismiss() }
                    .id(ObjectIdentifier(controller))
            } else {
                VStack(spacing: Theme.Space.xl) {
                    EmptyState(systemImage: "circle.dashed",
                               title: "No Halo connected",
                               message: "Pair or reconnect your Halo first.")
                    PrimaryButton("Close", kind: .secondary) { dismiss() }
                        .padding(.horizontal, Theme.Space.xl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .haloScreenBackground()
            }
        }
        .haloTheme()
    }
}

private struct RecoveryWizardContent: View {
    @ObservedObject var controller: DeviceController
    let close: () -> Void

    @EnvironmentObject private var central: BluetoothCentral
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var watcher = RebootWatcher()

    /// 1 explain/recover · 2 reboot · 3 done.
    @State private var step: Int
    /// A `recover()` / `reconnectAndFinish()` started from this wizard is in flight.
    @State private var busy = false

    init(controller: DeviceController, close: @escaping () -> Void) {
        self.controller = controller
        self.close = close
        let initial: Int
        switch controller.phase {
        case .needsReboot: initial = 2
        case .ready: initial = 3
        default: initial = 1
        }
        _step = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.m)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    illustration
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(.system(.title, weight: .heavy))
                            .foregroundStyle(Theme.text)
                        Text(message)
                            .font(.body)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stepDetail
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
            }

            footer
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.l)
        }
        .haloScreenBackground()
        .onAppear {
            if step == 2 { startWatching() }
        }
        .onDisappear { watcher.stop() }
        .onChange(of: controller.phase) { _, phase in phaseChanged(phase) }
        .sensoryFeedback(.success, trigger: step) { _, new in new == 3 }
        .sensoryFeedback(.error, trigger: errorText) { _, new in new != nil }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text("STEP \(step) OF 3")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Cancel") {
                watcher.stop()
                close()
            }
            .font(.body.weight(.semibold))
            .tint(Theme.info)
            .foregroundStyle(Theme.info)
            .frame(minHeight: Theme.minTarget)
        }
    }

    private var illustration: some View {
        ZStack {
            switch step {
            case 1:
                Image(systemName: "key.horizontal")
                    .font(.system(size: 80, weight: .regular))
                    .foregroundStyle(Theme.info)
            case 2:
                PulsingSymbol(systemName: "arrow.counterclockwise.circle", color: Theme.warn, size: 88)
            default:
                Image(systemName: "checkmark")
                    .font(.system(size: 80, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var title: LocalizedStringKey {
        switch step {
        case 1: return "Recover your Halo"
        case 2: return "Reboot the Halo"
        default: return "Done"
        }
    }

    private var message: LocalizedStringKey {
        switch step {
        case 1: return "This Halo has a password this iPhone doesn't know, probably from the old app. We'll reset it and give it this iPhone's password, kept in your Keychain."
        case 2: return "The Halo is un-paired. Due to a firmware quirk it keeps its old password until it restarts once: disconnect and reconnect the battery, or let it drain. Wait here — we'll notice when it comes back."
        default: return "Your Halo is yours again. Its password is kept in this iPhone's Keychain."
        }
    }

    @ViewBuilder private var stepDetail: some View {
        if let errorText {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.danger)
                Text(verbatim: errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                Text("Keep the Halo close and awake, then try again.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .haloCard()
        } else if let progress = progressText {
            HStack(spacing: Theme.Space.m) {
                ProgressView()
                Text(progress)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .haloCard()
            .accessibilityElement(children: .combine)
        }

        if step == 2 {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                rebootOption("Disconnect the battery — cleanest",
                             "Open the ring (gentle heat to soften the adhesive + plastic picks, go along the seam). Unplug the battery connector, wait ~10 s, plug it back in.")
                Divider().overlay(Theme.stroke)
                rebootOption("Drain the battery — no tools",
                             "Unplug it and leave it until it dies completely, then charge it. It cold-boots on power-up.")
                Divider().overlay(Theme.stroke)
                rebootOption("UART / SWD — if already open",
                             "Reset the nRF, or delete the StandbyState file over the STM32 console.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .haloCard()

            Text("Why: the firmware only reloads the (now-cleared) password at boot. There is no safe over-the-air reboot — the ring rejects reboot/standby commands unless an app is already paired.")
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
    }

    private func rebootOption(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "bolt.circle")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var footer: some View {
        switch step {
        case 1:
            if errorText != nil || controller.phase == .disconnected {
                PrimaryButton("Try again", systemImage: "arrow.clockwise") {
                    run { await controller.reconnectAndFinish() }
                }
                .disabled(busy)
            } else {
                PrimaryButton("Recover", systemImage: "key.horizontal") {
                    run { await controller.recover() }
                }
                .disabled(busy || controller.phase != .needsRecovery)
            }
        case 2:
            PrimaryButton(errorText != nil ? "Try again" : "I've rebooted it") { finish() }
                .disabled(busy)
        default:
            PrimaryButton("Continue") { close() }
        }
    }

    // MARK: State

    private var errorText: String? {
        if case .error(let message) = controller.phase { return message }
        return nil
    }

    private var progressText: LocalizedStringKey? {
        switch step {
        case 1:
            switch controller.phase {
            case .connecting, .authenticating: return "Connecting…"
            case .recovering: return "Recovering…"
            case .disconnected: return nil
            default: return busy ? "Recovering…" : nil
            }
        case 2:
            if busy {
                switch controller.phase {
                case .connecting: return "Waiting for the Halo to come back…"
                default: return "Finishing the recovery…"
                }
            }
            return watcher.sawGone ? "Halo off — waiting for it to come back…" : "Waiting for the Halo…"
        default:
            return nil
        }
    }

    private func phaseChanged(_ phase: DeviceController.Phase) {
        switch phase {
        case .needsReboot:
            step = 2
            if !busy { startWatching() }
        case .ready:
            watcher.stop()
            step = 3
        default:
            break
        }
    }

    /// Run a controller action; afterwards, if the ring still has to reboot, resume watching.
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        watcher.stop()
        Task { @MainActor in
            await action()
            busy = false
            if controller.phase == .needsReboot { startWatching() }
        }
    }

    /// Step 2: reconnect to the rebooted ring and finish (`reconnectAndFinish()` re-runs the
    /// recovery, which succeeds once the firmware has reloaded its now-empty password).
    private func finish() {
        run { await controller.reconnectAndFinish() }
    }

    private func startWatching() {
        if !controller.isDemo {
            // Let go of the (un-paired) link so the ring advertises again while it's alive — the
            // watcher can then see it vanish when it's powered off and reappear after the boot.
            controller.close()
        }
        watcher.start(deviceID: controller.device.id, demo: controller.isDemo, central: central) {
            finish()
        }
    }
}

/// Step 2 auto-advance: detects the ring being power-cycled without any BLE command (the firmware
/// rejects reboot commands while un-paired). Scans in short windows for the ring's identifier;
/// once it has been **missing for a whole window** (powered off) and is **seen again** (booted and
/// advertising), it calls `onBack` — once. A ring that never disappears never triggers, so a
/// still-running ring isn't hammered with recovery attempts; the manual button stays available.
/// In demo mode the "reboot" is simulated after a few seconds.
@MainActor
final class RebootWatcher: ObservableObject {
    /// The ring has been missing for at least one scan window (probably powered off).
    @Published private(set) var sawGone = false
    private var task: Task<Void, Never>?
    private weak var central: BluetoothCentral?

    /// One scan window = `pollsPerWindow` × 0.5 s.
    private let pollsPerWindow = 10

    func start(deviceID: UUID, demo: Bool, central: BluetoothCentral,
               onBack: @escaping @MainActor () -> Void) {
        stop()
        sawGone = false
        self.central = demo ? nil : central
        task = Task { [weak self] in
            if demo {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.sawGone = true
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                onBack()
                return
            }
            // Give the link teardown a moment before the first window.
            try? await Task.sleep(for: .seconds(2))
            let polls = self?.pollsPerWindow ?? 10
            while !Task.isCancelled {
                guard central.state == .poweredOn else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                central.startScan()
                var seen = false
                for _ in 0..<polls {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { break }
                    if central.discovered.contains(where: { $0.id == deviceID }) { seen = true; break }
                }
                central.stopScan()
                guard !Task.isCancelled, let watcher = self else { return }
                if seen && watcher.sawGone {
                    SH2Log.log("recovery: the Halo is back after a power-cycle — finishing")
                    watcher.task = nil
                    onBack()
                    return
                }
                if !seen && !watcher.sawGone {
                    SH2Log.log("recovery: the Halo stopped advertising — waiting for it to boot")
                    watcher.sawGone = true
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        if task != nil { central?.stopScan() }
        task?.cancel()
        task = nil
    }
}

/// An SF Symbol that gently pulses (static with Reduce Motion).
struct PulsingSymbol: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 80

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .opacity(dim && !reduceMotion ? 0.4 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
