import SwiftUI
import CoreBluetooth
import CoreLocation
import UserNotifications

/// First-use flow (UX_DESIGN §4.1 / §5.1), full screen:
/// 1 Welcome → 2 Pair (auto-scan; a single Halo is highlighted; "Try without a Halo" = demo;
/// a handshake that needs recovery opens the recovery wizard, then continues) → 3 Permissions
/// (location + notifications, each explained before the system prompt) → 4 Account (optional) →
/// the Map tab. Pairing saves "my Halo" (`HaloConnection.pair(with:)`).
struct OnboardingView: View {
    enum Step: Int { case welcome, pair, permissions, account }

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeStep { go(.pair) }
                    .transition(transition)
            case .pair:
                PairStep { go(.permissions) }
                    .transition(transition)
            case .permissions:
                PermissionsStep { go(.account) }
                    .transition(transition)
            case .account:
                AccountStep { useServer in settings.completeOnboarding(useServer: useServer) }
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .haloScreenBackground()
    }

    private var transition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity)
    }

    private func go(_ next: Step) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { step = next }
        }
    }
}

// MARK: - Shared layout

/// Progress bars + big title + subtitle, scrollable content and a bottom button area.
private struct StepScaffold<Content: View, Footer: View>: View {
    let progress: Int
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content
    let footer: Footer

    init(progress: Int,
         title: LocalizedStringKey,
         subtitle: LocalizedStringKey,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.progress = progress
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingProgress(current: progress, total: 3)
                .padding(.top, Theme.Space.l)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(title)
                            .font(.system(.largeTitle, weight: .heavy))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.xl)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: Theme.Space.s) { footer }
                .padding(.bottom, Theme.Space.l)
        }
        .padding(.horizontal, Theme.Space.xl)
    }
}

/// Three segment bars (pair · permissions · account).
private struct OnboardingProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Theme.accent : Theme.stroke)
                    .frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current) of \(total)"))
    }
}

// MARK: - 1 Welcome

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Space.xl)
            VStack(spacing: 36) {
                WelcomeRing()
                    .frame(width: 200, height: 200)
                VStack(spacing: Theme.Space.m) {
                    Text("Your Halo,\nalive again.")
                        .font(.system(.largeTitle, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Follow your GPX routes on the ring, turn on the light and protect your bike. No account required.")
                        .font(.body)
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.xl)
            PrimaryButton("Get started") { next() }
                .padding(.bottom, Theme.Space.l)
        }
        .padding(.horizontal, 28)
    }
}

/// The welcome ring: an accent arc slowly turning around a clock-like centre (static with
/// Reduce Motion).
private struct WelcomeRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surface2, lineWidth: 16)
                .padding(22)
            Circle()
                .trim(from: 0, to: 0.67)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .padding(22)
                .rotationEffect(.degrees(spin ? 270 : -90))
            Circle()
                .fill(Theme.surface)
                .padding(50)
            ClockHands()
                .stroke(Theme.text, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct ClockHands: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 200
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - 28 * s))
        p.addLine(to: c)
        p.addLine(to: CGPoint(x: c.x + 18 * s, y: c.y + 12 * s))
        return p
    }
}

// MARK: - 2 Pair

private struct PairStep: View {
    let next: () -> Void

    @EnvironmentObject private var central: BluetoothCentral
    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var router: AppRouter

    /// The device the user tapped (kept even if a later scan no longer lists it).
    @State private var paired: DiscoveredDevice?
    @State private var advancing = false

    private var devices: [DiscoveredDevice] {
        var list = central.discovered
        if let paired, !list.contains(paired) { list.insert(paired, at: 0) }
        return list
    }

    var body: some View {
        StepScaffold(progress: 1,
                     title: "Pair your Halo",
                     subtitle: "Tap the ring to wake it up and bring your phone close.") {
            RadarView(active: central.isScanning || connection.state == .connecting)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            deviceSection
        } footer: {
            if connection.state == .connected && paired == nil && !connection.isDemo {
                // Onboarding re-run with my Halo already connected.
                PrimaryButton("Continue") { next() }
            }
            Button {
                central.stopScan()
                connection.startDemo()
                next()
            } label: {
                Label("Try without a Halo (demo mode)", systemImage: "wand.and.stars")
            }
            .buttonStyle(.haloSecondary)
            Button {
                central.stopScan()
                next()
            } label: {
                Text("Not now")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onAppear { startScanIfPossible() }
        .onDisappear { central.stopScan() }
        .onChange(of: central.state) { _, s in if s == .poweredOn { startScanIfPossible() } }
        .onChange(of: connection.state) { _, s in
            // Handshake done (directly, or after the recovery wizard) → Permissions.
            guard paired != nil, s == .connected, !advancing else { return }
            advancing = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                next()
            }
        }
        .onChange(of: router.showRecovery) { _, shown in
            // Wizard cancelled with nothing connected: keep looking.
            if !shown && paired == nil && connection.state == .disconnected { startScanIfPossible() }
        }
        .sensoryFeedback(.success, trigger: connection.state) { _, new in new == .connected && paired != nil }
    }

    private func startScanIfPossible() {
        // Bluetooth starts on demand, and the pairing step is the demand: without this, a phone
        // with no saved Halo would wait for `.poweredOn` forever. The `onChange` on `central.state`
        // starts the scan once it reports in.
        central.activate()
        if central.state == .poweredOn && !central.isScanning { central.startScan() }
    }

    private func pair(_ device: DiscoveredDevice) {
        if device.id == paired?.id && connection.state == .needsRecovery {
            router.openRecovery()
            return
        }
        paired = device
        advancing = false
        connection.pair(with: device)
    }

    // MARK: Devices

    @ViewBuilder private var deviceSection: some View {
        if central.state != .poweredOn && paired == nil {
            bluetoothMessage
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Found")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textDim)
                if devices.isEmpty {
                    HStack(spacing: Theme.Space.m) {
                        ProgressView()
                        Text("Scanning… tap or charge your SmartHalo so it advertises.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .haloCard()
                } else {
                    ForEach(devices) { device in
                        deviceRow(device, highlighted: devices.count == 1 || device.id == paired?.id)
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: DiscoveredDevice, highlighted: Bool) -> some View {
        let isPaired = device.id == paired?.id
        let busy = isPaired && (connection.state == .connecting || connection.state == .connected)
        return Button { pair(device) } label: {
            HStack(spacing: 14) {
                Circle()
                    .stroke(Theme.accent, lineWidth: 5)
                    .frame(width: 30, height: 30)
                    .padding(5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.name)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text(isPaired ? pairingStatus : signalLabel(device.rssi))
                        .font(.footnote)
                        .foregroundStyle(isPaired ? pairingColor : Theme.textDim)
                }
                Spacer(minLength: Theme.Space.s)
                if isPaired && connection.state == .connecting {
                    ProgressView()
                } else if isPaired && connection.state == .connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
            .haloCard(stroke: highlighted ? Theme.accent : Theme.stroke)
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .accessibilityElement(children: .combine)
    }

    private var pairingStatus: LocalizedStringKey {
        switch connection.state {
        case .connecting: return "Connecting and verifying…"
        case .connected: return "Connected"
        case .needsRecovery: return "Needs re-pairing · tap to recover"
        case .disconnected: return "Couldn't connect · tap to try again"
        }
    }

    private var pairingColor: Color {
        switch connection.state {
        case .connected: return Theme.accent
        case .connecting: return Theme.textDim
        case .needsRecovery, .disconnected: return Theme.warn
        }
    }

    private func signalLabel(_ rssi: Int) -> LocalizedStringKey {
        if rssi == 0 || rssi >= -65 { return "Strong signal · tap to pair" }
        if rssi >= -80 { return "Good signal · tap to pair" }
        return "Weak signal · bring the phone closer"
    }

    private var bluetoothMessage: some View {
        let (text, icon): (LocalizedStringKey, String) = {
            switch central.state {
            case .unknown, .resetting: return ("Starting Bluetooth…", "antenna.radiowaves.left.and.right")
            case .poweredOff: return ("Bluetooth is off. Turn it on in Settings.", "wifi.slash")
            case .unauthorized: return ("Bluetooth permission denied. Enable it in Settings.", "hand.raised")
            case .unsupported: return ("Bluetooth LE is not supported on this device.", "xmark.octagon")
            default: return ("Bluetooth unavailable.", "questionmark")
            }
        }()
        return Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.warn)
            .frame(maxWidth: .infinity, alignment: .leading)
            .haloCard()
    }
}

/// Radar-style pulses while scanning / connecting (a still ring with Reduce Motion).
private struct RadarView: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<2, id: \.self) { i in
                            let phase = (t / 2 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(Theme.accent, lineWidth: 2)
                                .frame(width: 200, height: 200)
                                .scaleEffect(0.36 + 0.64 * phase)
                                .opacity(1 - phase)
                        }
                    }
                }
            } else if active {
                Circle()
                    .stroke(Theme.accent.opacity(0.4), lineWidth: 2)
                    .frame(width: 150, height: 150)
            }
            Circle()
                .fill(Theme.surface)
                .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 2))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 3 Permissions

private struct PermissionsStep: View {
    let next: () -> Void

    @StateObject private var location = LocationTracker()
    @ObservedObject private var notifier = AlarmNotifier.shared
    @State private var locationStatus: CLAuthorizationStatus = .notDetermined
    @Environment(\.openURL) private var openURL

    var body: some View {
        StepScaffold(progress: 2,
                     title: "Two permissions",
                     subtitle: "Only for what you see here.") {
            VStack(spacing: Theme.Space.m) {
                PermissionRow(systemImage: "location.fill",
                              tint: Theme.info,
                              title: "Location",
                              detail: "To guide you along the route and show you on the map.",
                              state: locationState) {
                    location.requestAuthorization()
                } openSettings: { openSystemSettings() }

                PermissionRow(systemImage: "bell.fill",
                              tint: Theme.warn,
                              title: "Notifications",
                              detail: "To warn you when the Halo's battery runs low.",
                              state: notificationState) {
                    Task { await notifier.requestAuthorization() }
                } openSettings: { openSystemSettings() }
            }
            Text("You can change both later in the iPhone's Settings.")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
        } footer: {
            PrimaryButton("Continue") { next() }
        }
        .onAppear {
            location.onAuth = { status in locationStatus = status }
            locationStatus = location.authorizationStatus
            Task { await notifier.refreshStatus() }
        }
    }

    private var locationState: PermissionRow.Status {
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        default: return .ask
        }
    }

    private var notificationState: PermissionRow.Status {
        switch notifier.status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default: return .ask
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

private struct PermissionRow: View {
    enum Status { case ask, granted, denied }

    let systemImage: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let state: Status
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Space.s)
            button
        }
        .haloCard(padding: 18)
    }

    @ViewBuilder private var button: some View {
        switch state {
        case .ask:
            Button(action: allow) {
                Text("Allow")
                    .pill(fill: Theme.accent, text: Theme.onAccent)
            }
            .buttonStyle(PressableStyle())
        case .granted:
            Label("Permission granted", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .pill(fill: Theme.surface2, text: Theme.accent)
                .accessibilityLabel(Text("Permission granted"))
        case .denied:
            Button(action: openSettings) {
                Text("Settings")
                    .pill(fill: Theme.surface2, text: Theme.text)
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint(Text("Permission denied. Opens the iPhone's Settings."))
        }
    }
}

private extension View {
    /// Small capsule button look (permission rows).
    func pill(fill: Color, text: Color) -> some View {
        self
            .font(.subheadline.weight(.bold))
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(fill, in: Capsule())
            .frame(minHeight: Theme.minTarget)
            .contentShape(Rectangle())
    }
}

// MARK: - 4 Account

private struct AccountStep: View {
    let finish: (_ useServer: Bool) -> Void

    @State private var showLogin = false
    @State private var loggedIn = false

    var body: some View {
        StepScaffold(progress: 3,
                     title: "Sync your rides?",
                     subtitle: "Connect your own SmartHalo server to save your rides. It's optional: everything works over Bluetooth alone, and you can do it later in Settings.") {
            Image(systemName: "server.rack")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Theme.info)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
                .accessibilityHidden(true)
        } footer: {
            // Same visual weight on purpose (UX_DESIGN §4.1): the account is optional.
            PrimaryButton("Connect server", kind: .secondary) { showLogin = true }
            PrimaryButton("Not now", kind: .secondary) { finish(false) }
        }
        .sheet(isPresented: $showLogin, onDismiss: {
            if loggedIn { finish(true) }
        }) {
            NavigationStack {
                LoginView { loggedIn = true }
                    .haloListStyle()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showLogin = false }
                        }
                    }
            }
            .haloTheme()
        }
    }
}
