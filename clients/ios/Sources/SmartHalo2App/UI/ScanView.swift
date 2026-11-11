import SwiftUI
import CoreBluetooth

/// Pairing list: scan for nearby SmartHalo devices; tap one to make it "my Halo" (saved and
/// auto-connected from then on). Shown as the Halo tab's root when nothing is paired, and pushed
/// from Settings › Pair another Halo. Hosted inside a `NavigationStack` (it has none of its own).
/// (The onboarding has its own pairing step, `OnboardingView` › Pair.) A pairing whose handshake
/// needs recovery opens the recovery wizard via `HaloConnection.pairingNeedsRecovery`.
struct ScanView: View {
    /// Called right after a device is chosen (e.g. pop back to the Halo cards).
    var onPaired: (() -> Void)? = nil

    @EnvironmentObject private var central: BluetoothCentral
    @EnvironmentObject private var connection: HaloConnection

    var body: some View {
        Group {
            switch central.state {
            case .poweredOn:
                deviceList
            case .unknown, .resetting:
                centered("Starting Bluetooth…", systemImage: "antenna.radiowaves.left.and.right")
            case .poweredOff:
                centered("Bluetooth is off. Turn it on in Settings.", systemImage: "wifi.slash")
            case .unauthorized:
                centered("Bluetooth permission denied. Enable it in Settings.", systemImage: "hand.raised")
            case .unsupported:
                centered("Bluetooth LE is not supported on this device.", systemImage: "xmark.octagon")
            @unknown default:
                centered("Bluetooth unavailable.", systemImage: "questionmark")
            }
        }
        .haloScreenBackground()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if central.isScanning {
                    Button("Stop") { central.stopScan() }
                } else {
                    Button("Scan") { central.startScan() }
                        .disabled(central.state != .poweredOn)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !connection.isDemo {
                Button {
                    connection.startDemo()
                    onPaired?()
                } label: {
                    Label("Try the demo — no device needed", systemImage: "wand.and.stars")
                }
                .buttonStyle(HaloButtonStyle(kind: .secondary))
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.s)
            }
        }
        .onAppear {
            // Bluetooth starts on demand: this screen is the demand when no Halo is saved. The
            // scan itself waits for `.poweredOn`, which the `onChange` below picks up.
            central.activate()
            if central.state == .poweredOn && !central.isScanning { central.startScan() }
        }
        .onChange(of: central.state) { _, s in if s == .poweredOn { central.startScan() } }
        .onDisappear { central.stopScan() }
    }

    private var deviceList: some View {
        List {
            Section {
                if central.discovered.isEmpty {
                    HStack(spacing: Theme.Space.m) {
                        if central.isScanning { ProgressView() }
                        Text(central.isScanning
                             ? "Scanning… tap or charge your SmartHalo so it advertises."
                             : "No devices yet. Tap Scan.")
                            .foregroundStyle(Theme.textDim)
                    }
                } else {
                    ForEach(central.discovered) { device in
                        Button {
                            connection.pair(with: device)
                            onPaired?()
                        } label: {
                            deviceRow(device)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Nearby Halos")
            } footer: {
                Text("BLE-only — no account or internet needed. If your unit never appears, it may advertise only its 16-bit id; see the README for the broad-scan option.")
            }
            .listRowBackground(Theme.surface)
        }
        .haloListStyle()
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "circle.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.name).font(.headline).foregroundStyle(Theme.text)
                Text(verbatim: device.id.uuidString).font(.caption2).foregroundStyle(Theme.textDim)
            }
            Spacer()
            Text(verbatim: "\(device.rssi) dBm").font(.caption).foregroundStyle(Theme.textDim)
        }
        .frame(minHeight: Theme.minTarget)
        .contentShape(Rectangle())
    }

    private func centered(_ text: LocalizedStringKey, systemImage: String) -> some View {
        ContentUnavailableView(text, systemImage: systemImage)
    }
}
