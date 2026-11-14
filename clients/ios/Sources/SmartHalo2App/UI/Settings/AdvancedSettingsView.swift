import SwiftUI
import Combine
import LocalAuthentication
import SH2Protocol

/// Settings › Advanced (UX_DESIGN §4.6): firmware info, maintenance (clock & language, compass),
/// sound & touch, live log, demo mode (+ "Simulate alarm"), ride recording, DFU explainer, saved
/// password, shut down.
/// Folds in the old M4 Device settings screen.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var connection: HaloConnection

    var body: some View {
        ObservedAdvancedList(controller: connection.controller)
            .id(connection.controller.map { ObjectIdentifier($0) })
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The list itself; observes the (optional) controller through `ControllerBox`.
private struct ObservedAdvancedList: View {
    @StateObject private var box: ControllerBox
    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings

    @State private var confirmShutdown = false
    @State private var revealedPassword: String?
    @State private var copiedPassword = false
    @State private var showPasswordEntry = false
    @State private var enteredPassword = ""
    @State private var applyingPassword = false
    @State private var passwordResult: LocalizedStringKey?
    @State private var confirmForgetPassword = false
    @State private var simulating = false
    @AppStorage(RideRecorder.enabledKey) private var recordRides = false
    /// The newest recorded ride, read once on appear (not a directory listing per render).
    @State private var lastRide: URL?

    init(controller: DeviceController?) {
        _box = StateObject(wrappedValue: ControllerBox(controller))
    }

    private var controller: DeviceController? { box.controller }
    private var isReady: Bool { connection.state == .connected && controller?.phase == .ready }

    var body: some View {
        List {
            firmwareSection
            maintenanceSection
            toolsSection
            demoSection
            navigationSection
            mapSection
            routingSection
            recordingSection
            passwordSection

            Section {
                Text("Over-the-air firmware flashing isn't implemented. It needs the signed .dfu packages and a careful bootloader flow — doing it wrong can brick the device, so it's intentionally left out.")
                    .font(.footnote).foregroundStyle(Theme.textDim)
            } header: {
                Text("Firmware update (DFU)")
            }
            .listRowBackground(Theme.surface)

            Section {
                if connection.state == .connected && !connection.isDemo {
                    Button { connection.disconnect() } label: {
                        Label("Disconnect", systemImage: "bolt.horizontal.circle")
                    }
                }
                Button(role: .destructive) { confirmShutdown = true } label: {
                    Label("Shut down the Halo", systemImage: "power")
                        .foregroundStyle(Theme.danger)
                }
                .disabled(!isReady)
            }
            .listRowBackground(Theme.surface)
        }
        .haloListStyle()
        .confirmationDialog("Shut down the Halo?", isPresented: $confirmShutdown, titleVisibility: .visible) {
            Button("Shut down", role: .destructive) {
                guard let controller else { return }
                Task { await controller.shutdownDevice() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The ring powers off; wake it by plugging it in or tapping it.")
        }
        .confirmationDialog("Forget saved password?", isPresented: $confirmForgetPassword, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { controller?.forgetSavedPassword() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this phone's stored device password. You'll need to recover/re-pair to control the ring again.")
        }
        // On the List, not on a Section: presentations attached to list sections are unreliable.
        .sheet(isPresented: $showPasswordEntry) {
            if let controller { passwordEntrySheet(controller) }
        }
        .task {
            lastRide = RideRecorder.rides.first
            guard let controller, isReady else { return }
            await controller.refreshDeviceState()
        }
    }

    // MARK: Sections

    private var firmwareSection: some View {
        Section {
            LabeledContent("Firmware", value: controller?.firmwareVersion ?? "—")
            LabeledContent("Bootloader", value: controller?.bootloaderVersion ?? "—")
            LabeledContent("Serial", value: controller?.serial ?? "—")
            LabeledContent("State", value: controller?.deviceStateHex ?? "—")
                .font(.system(.caption, design: .monospaced))
            LabeledContent("Alarm report", value: controller?.alarmReportHex ?? "—")
                .font(.system(.caption, design: .monospaced))
            Button {
                guard let controller else { return }
                Task {
                    await controller.refreshInfo()
                    await controller.refreshDeviceState()
                    await controller.refreshAlarmReport()
                }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .disabled(!isReady)
        } header: {
            Text("Firmware & information")
        }
        .listRowBackground(Theme.surface)
    }

    private var maintenanceSection: some View {
        Section {
            Button {
                guard let controller else { return }
                Task { await controller.syncTime() }
            } label: {
                Label("Sync clock & language", systemImage: "clock.arrow.2.circlepath")
            }
            // No "Calibrate compass": the SmartHalo 2's firmware has no handler for {4,3} (it
            // answers UNIMPLEMENTED) and nothing reads its magnetometer over Bluetooth.
        } header: {
            Text("Maintenance")
        }
        .disabled(!isReady)
        .listRowBackground(Theme.surface)
    }

    private var toolsSection: some View {
        Section {
            NavigationLink(value: HaloRoute.soundTouch) {
                HStack {
                    Label("Sound & touch", systemImage: "speaker.wave.2")
                    Spacer()
                    SoonBadge()
                }
            }
            .disabled(controller == nil)
            NavigationLink(value: HaloRoute.liveLog) {
                Label("Live log", systemImage: "terminal")
            }
        }
        .listRowBackground(Theme.surface)
    }

    /// The classic engine stays available to compare with the matched one (MAP_MATCHING_SPEC §10).
    private var navigationSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.navigationEngine == .classic },
                set: { settings.navigationEngine = $0 ? .classic : .matched }
            )) {
                Label("Classic navigation", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
        } header: {
            Text("Navigation")
        } footer: {
            Text("Locates you on the route the way the official SmartHalo app does: the current stretch only, and no wrong-way warning. From the next ride.")
        }
        .listRowBackground(Theme.surface)
    }

    /// The map engine (docs/APP_SPEC.md M17): Apple Maps until MapLibre has been tried on a phone.
    private var mapSection: some View {
        Section {
            Picker(selection: $settings.mapEngine) {
                ForEach(MapEngine.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            } label: {
                Label("Map engine", systemImage: "map")
            }
            NavigationLink(value: HaloRoute.offlineMaps) {
                Label("Offline maps", systemImage: "arrow.down.circle")
            }
        } header: {
            Text("Map")
        } footer: {
            Text("MapLibre draws OpenStreetMap data from OpenFreeMap, with Spain's IGN topo and satellite layers, shaded relief and CyclOSM's cycle network, and can save areas for offline use. The 3D route view stays on Apple Maps.")
        }
        .listRowBackground(Theme.surface)
    }

    /// Where bike routes come from: a BRouter server of the rider's, or Apple Maps.
    private var routingSection: some View {
        Section {
            TextField("BRouter URL", text: $settings.brouterURLString, prompt: Text(verbatim: "https://brouter.example.org"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("BRouter server")
        } footer: {
            Text("The base URL of a BRouter server (or a proxy to one, such as your sh2-server's). Routes then use its City, Road, Gravel and MTB profiles with elevation and roundabouts, and a way back is asked for when you leave the route. Empty: routes come from Apple Maps.")
        }
        .listRowBackground(Theme.surface)
    }

    private var recordingSection: some View {
        Section {
            Toggle(isOn: $recordRides) {
                Label("Record rides", systemImage: "record.circle")
            }
            if let last = lastRide {
                ShareLink(item: last) {
                    Label("Share the last ride", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Ride recording")
        } footer: {
            Text("Saves every GPS fix, what the screen showed and what the ring was told, to find navigation bugs. Includes your route: share it only if you want to.")
        }
        .listRowBackground(Theme.surface)
    }

    private var demoSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { connection.isDemo },
                set: { on in
                    if on { connection.startDemo() } else { connection.stopDemo() }
                }
            )) {
                Label("Demo mode", systemImage: "wand.and.stars")
            }
            if connection.isDemo, let controller {
                Button {
                    simulating = true
                    Task {
                        await controller.simulateAlarm()
                        simulating = false
                    }
                } label: {
                    HStack {
                        Label("Simulate alarm", systemImage: "bell.and.waves.left.and.right")
                        if simulating { Spacer(); ProgressView() }
                    }
                }
                .disabled(simulating || !isReady)

                Button {
                    controller.simulateNeedsRecovery()
                    router.openRecovery()
                } label: {
                    Label("Simulate re-pair", systemImage: "key.horizontal")
                }
                .disabled(!isReady)

                if let pw = controller.newlyGeneratedPassword {
                    LabeledContent("New device password") {
                        Text(verbatim: pw)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Demo")
        } footer: {
            Text(connection.isDemo
                 ? LocalizedStringKey("A simulated Halo — every feature is safe to try. “Simulate alarm” walks away, moves the bike and comes back (turn the alarm on first): you get the recap. “Simulate re-pair” walks you through the recovery wizard.")
                 : LocalizedStringKey("Try every screen with a simulated Halo, no device needed. Your saved Halo is kept."))
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder private var passwordSection: some View {
        if let controller, !controller.isDemo {
            Section {
                if let pw = revealedPassword {
                    Text(verbatim: pw)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(Text("Device password"))
                    Button {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": pw]],
                                                      options: [.localOnly: true,
                                                                .expirationDate: Date().addingTimeInterval(120)])
                        copiedPassword = true
                    } label: {
                        Label(copiedPassword ? LocalizedStringKey("Copied (clears in 2 min)")
                                             : LocalizedStringKey("Copy password"),
                              systemImage: copiedPassword ? "checkmark" : "doc.on.doc")
                    }
                    Button { revealedPassword = nil; copiedPassword = false } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                } else {
                    Button { Task { await revealPassword(controller) } } label: {
                        Label("Show password", systemImage: "eye")
                    }
                    .disabled(controller.savedPassword == nil)
                }

                Button { enteredPassword = ""; passwordResult = nil; showPasswordEntry = true } label: {
                    Label("Enter a saved password…", systemImage: "key.viewfinder")
                }

                Toggle(isOn: $settings.syncPasswordsToICloud) {
                    Label("Sync with iCloud Keychain", systemImage: "icloud")
                }
                .tint(Theme.accent)

                if connection.state == .needsRecovery {
                    Button { router.openRecovery() } label: {
                        Label("Re-pair (recovery)", systemImage: "key.horizontal")
                    }
                }
                Button(role: .destructive) { confirmForgetPassword = true } label: {
                    Label("Forget saved password", systemImage: "key.slash")
                        .foregroundStyle(Theme.danger)
                }
            } header: {
                Text("Device password")
            } footer: {
                Text("The ring only accepts the password this app set during recovery. Save a copy in your password manager: if it's lost, recovering again needs a cold reboot of the ring. iCloud Keychain sync needs iCloud Keychain turned on, and may not work with free-account (SideStore) signing. Another iPhone tries synced passwords automatically.")
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func passwordEntrySheet(_ controller: DeviceController) -> some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Device password", text: $enteredPassword)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                } footer: {
                    if let passwordResult {
                        Text(passwordResult).foregroundStyle(Theme.warn)
                    } else {
                        Text("Paste the password you saved (32 letters and digits). The app reconnects and checks it with the ring; if it's rejected, the current one is kept.")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .haloListStyle()
            .navigationTitle("Saved password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPasswordEntry = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if applyingPassword {
                        ProgressView()
                    } else {
                        Button("Use") {
                            applyingPassword = true
                            Task {
                                let ok = await controller.useSavedPassword(enteredPassword)
                                applyingPassword = false
                                if ok { showPasswordEntry = false } else { passwordResult = "The ring rejected that password." }
                            }
                        }
                        .disabled(enteredPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Show the password only after Face ID / Touch ID / passcode.
    private func revealPassword(_ controller: DeviceController) async {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let reason = String(localized: "Show the Halo's device password")
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
            else { return }
        }
        revealedPassword = controller.savedPassword
    }
}

/// Lets a view observe an optional `DeviceController` (`@ObservedObject` can't be optional).
@MainActor
private final class ControllerBox: ObservableObject {
    let controller: DeviceController?
    private var sub: AnyCancellable?

    init(_ controller: DeviceController?) {
        self.controller = controller
        sub = controller?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
