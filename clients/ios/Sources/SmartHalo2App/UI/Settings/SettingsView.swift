import SwiftUI
import UIKit
import UserNotifications

/// Settings (UX_DESIGN §4.6), pushed on the Halo tab (`HaloRoute.settings`): My Halo · Alarm ·
/// Call alerts · Rain alert · Account · General · Advanced. Replaces the old Settings sheet and the M4 Device settings screen.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var notifier = AlarmNotifier.shared
    @ObservedObject private var calls = CallAlertController.shared

    @State private var confirmForget = false
    @State private var confirmModeChange = false
    @State private var showTapCode = false

    private var controller: DeviceController? { connection.controller }
    private var isReady: Bool { connection.state == .connected }

    var body: some View {
        Form {
            myHaloSection
            alarmSection
            callAlertsSection
            rainAlertSection
            accountSection
            generalSection

            Section {
                NavigationLink(value: HaloRoute.advanced) {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            } footer: {
                Text("Firmware info, maintenance, sound & touch, live log, demo mode and shut down.")
            }
            .listRowBackground(Theme.surface)

            Section {
                LabeledContent("Version", value: Self.appVersion)
                Link("Project on GitHub", destination: URL(string: "https://github.com/cyberlynx33/open-rehalo")!)
            } header: {
                Text("About")
            } footer: {
                Text("Open-source revival of the SmartHalo 2. BLE-only by default; the optional server is a self-hosted sh2-server instance.")
            }
            .listRowBackground(Theme.surface)
        }
        .haloListStyle()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await notifier.refreshStatus()
            if auth.isLoggedIn { await auth.refreshProfile() }
        }
        .confirmationDialog("Forget this Halo?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                connection.forget()
                router.showHaloHome()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app stops connecting to it. Its password stays in the Keychain, so pairing the same Halo again won't need a recovery.")
        }
        .confirmationDialog("Change connection mode?", isPresented: $confirmModeChange, titleVisibility: .visible) {
            Button("Change", role: .destructive) {
                auth.logout()
                settings.resetOnboarding()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be logged out and taken back to the welcome screen.")
        }
        // On the Form, not on a Section: presentations attached to list sections are unreliable.
        .sheet(isPresented: $showTapCode) {
            TapCodeSheet(controller: isReady ? controller : nil)
            .presentationBackground(Theme.surface2)
            .environmentObject(settings)
            .environmentObject(connection)
            .haloTheme()
        }
    }

    // MARK: My Halo

    private var myHaloSection: some View {
        Section {
            NavigationLink(value: HaloRoute.rename) {
                LabeledContent {
                    Text(verbatim: connection.displayName ?? "—")
                } label: {
                    Label("Name", systemImage: "character.cursor.ibeam")
                }
            }
            .disabled(!isReady)

            NavigationLink(value: HaloRoute.pair) {
                Label("Pair another Halo", systemImage: "plus.circle")
            }

            if connection.hasSavedHalo || connection.controller != nil {
                Button(role: .destructive) { confirmForget = true } label: {
                    Label("Forget this Halo", systemImage: "trash")
                        .foregroundStyle(Theme.danger)
                }
            }
        } header: {
            Text("My Halo")
        } footer: {
            if !isReady && connection.controller != nil {
                Text("Connect to the Halo to rename it.")
            }
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Alarm

    private var alarmSection: some View {
        Section {
            Button { showTapCode = true } label: {
                LabeledContent {
                    Text(verbatim: settings.alarmTapCode?.symbols ?? "—")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                } label: {
                    Label("Tap code", systemImage: "hand.tap")
                }
            }
            .disabled(!isReady)
            Picker(selection: Binding(
                get: { settings.alarmVigilant },
                set: { vigilant in
                    // Kept only if the Halo accepts it (the official app's severity switch).
                    guard let controller, isReady else { return }
                    Task { await controller.applyAlarmConfig(vigilant: vigilant) }
                }
            )) {
                Text("Lenient").tag(false)
                Text("Vigilant").tag(true)
            } label: {
                Label("Sensitivity", systemImage: "sensor.tag.radiowaves.forward")
            }
            .disabled(!isReady)
        } header: {
            Text("Alarm")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("**Auto activation.** When the alarm is on, the Halo arms itself as soon as you leave your bike, and disarms when you come back near it with this iPhone. It doesn't arm while charging.")
                Text("**Manual activation.** Phone out of battery? Tap your tap code on the Halo's touch surface to arm or disarm the alarm.")
                Text("When armed, persistent tampering with your bike sets off a loud alarm. Vigilant sounds sooner than Lenient.")
                if !isReady { Text("Connect to your Halo to change the alarm.") }
            }
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Alerts

    private var callAlertsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.callAlerts },
                set: { on in
                    settings.callAlerts = on
                    calls.refresh()
                }
            )) {
                Label("Show calls on the Halo", systemImage: "phone")
            }
            Toggle(isOn: Binding(
                get: { settings.callAlertSound },
                set: { on in
                    settings.callAlertSound = on
                    if !on { controller?.silenceIncomingCall() }
                }
            )) {
                Label("Call alert sound", systemImage: "speaker.wave.2")
            }
            .disabled(!settings.callAlerts)
            Button { calls.test() } label: {
                Label("Test alert", systemImage: "play.circle")
            }
            .disabled(!isReady || calls.testing)
        } header: {
            Text("Call alerts")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("A short tap on the Halo silences it")
                Text("Works while you navigate or ride. In the background it may arrive late, and with the app closed it can't alert. iOS doesn't say who is calling.")
            }
        }
        .tint(Theme.accent)
        .listRowBackground(Theme.surface)
    }

    private var rainAlertSection: some View {
        Section {
            Toggle(isOn: $settings.rainAlerts) {
                Label("Warn me on the Halo when rain is close during a ride", systemImage: "cloud.rain")
            }
            Button { RainAlertController.shared.test() } label: {
                Label("Test alert", systemImage: "play.circle")
            }
            .disabled(!isReady)
        } header: {
            Text("Rain alert")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("While you ride, your approximate location goes to Open-Meteo every 10 minutes.")
                Link("Weather data by Open-Meteo.com (CC BY 4.0)", destination: URL(string: "https://open-meteo.com/")!)
            }
        }
        .tint(Theme.accent)
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder private var notificationRow: some View {
        switch notifier.status {
        case .notDetermined:
            Button {
                Task { await notifier.requestAuthorization() }
            } label: {
                Label("Turn on notifications", systemImage: "bell.badge")
            }
        case .denied:
            Button { openSystemSettings() } label: {
                LabeledContent {
                    Text("Not allowed")
                } label: {
                    Label("Notifications", systemImage: "bell.slash")
                }
            }
        default:
            LabeledContent {
                Text("Allowed")
            } label: {
                Label("Notifications", systemImage: "bell")
            }
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if auth.isLoggedIn, let u = auth.user {
                LabeledContent("Signed in", value: u.displayName)
                if let email = u.email { LabeledContent("Email", value: email) }
                LabeledContent("Server", value: settings.serverURLString)
                NavigationLink(value: HaloRoute.rides) {
                    Label("Rides history", systemImage: "clock.arrow.circlepath")
                }
                Button(role: .destructive) { auth.logout() } label: {
                    Text("Log out").foregroundStyle(Theme.danger)
                }
            } else {
                LabeledContent {
                    Text("Not connected")
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
                NavigationLink(value: HaloRoute.login) {
                    Label("Connect to a server", systemImage: "link")
                }
            }
            Button { confirmModeChange = true } label: {
                LabeledContent {
                    Text(settings.useServer ? LocalizedStringKey("Server + Bluetooth") : LocalizedStringKey("Bluetooth-only"))
                } label: {
                    Label("Connection mode", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text("Account")
        } footer: {
            if !auth.isLoggedIn {
                Text("Controlling the ring works over Bluetooth without an account. The server only adds rides history & sync.")
            }
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Picker(selection: $settings.units) {
                ForEach(DistanceUnits.allCases) { u in
                    Text(u.label).tag(u)
                }
            } label: {
                Label("Units", systemImage: "ruler")
            }
            Button { openSystemSettings() } label: {
                LabeledContent {
                    Text(verbatim: Self.appLanguage)
                } label: {
                    Label("Language", systemImage: "globe")
                }
            }
            notificationRow
        } header: {
            Text("General")
        } footer: {
            Text("Units are used for distances, speed and elevation. The language follows the iPhone's settings for this app.")
        }
        .listRowBackground(Theme.surface)
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// The language the app is actually running in (from the bundle's localizations).
    static var appLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - Rename

struct RenameHaloView: View {
    @ObservedObject var controller: DeviceController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var connection: HaloConnection
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failed = false
    @State private var busy = false

    /// The nRF keeps this many bytes of the name and drops the rest.
    static let maxNameBytes = 19

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .onChange(of: name) { _, new in
                        let capped = Self.capped(new)
                        if capped != new { name = capped }
                    }
            } footer: {
                if failed {
                    Text("Couldn't rename the Halo. Check it's connected and try again.")
                        .foregroundStyle(Theme.danger)
                } else {
                    Text("The new name is stored on the Halo itself, up to 19 characters.")
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                Button(action: save) {
                    HStack {
                        if busy { ProgressView() }
                        Text("Save")
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .listRowBackground(Theme.surface)
        }
        .haloListStyle()
        .navigationTitle("Name")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if name.isEmpty { name = connection.displayName ?? "" } }
    }

    /// `name` cut to `maxNameBytes` of UTF-8 on a character boundary (accents and emoji take more
    /// than one byte, so fewer of them fit).
    static func capped(_ name: String) -> String {
        var out = ""
        for ch in name {
            guard out.utf8.count + String(ch).utf8.count <= maxNameBytes else { break }
            out.append(ch)
        }
        return out
    }

    private func save() {
        let trimmed = Self.capped(name.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty else { return }
        busy = true
        failed = false
        Task {
            // `renameDevice()` sends `deviceName`; if the ring refuses, the app shows the old name again.
            let previous = controller.deviceName
            controller.deviceName = trimmed
            let ok = await controller.renameDevice()
            busy = false
            if ok {
                if !controller.isDemo { settings.myHaloName = trimmed }
                dismiss()
            } else {
                controller.deviceName = previous
                failed = true
            }
        }
    }
}
