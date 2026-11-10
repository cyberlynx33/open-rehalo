import SwiftUI
import SH2Protocol

/// Halo tab (UX_DESIGN §4.5, Halo v2 option C): a compact header (live ring mirror, name, state,
/// battery, temperature, Settings) over three sections — Controls (Light, Alarm,
/// low-battery alert), Ring cards (the Halo's carousel) and Taps (tap shortcuts, alarm tap code).
/// Without a saved Halo it shows the pairing list (`ScanView`).
///
/// Everything else (Settings, Advanced, recovery, ring screens…) is pushed on this tab's
/// `NavigationStack` through `AppRouter.haloPath`, so a deep link (alarm notification, chip) can
/// pop straight back to the cards.
struct HaloTab: View {
    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.haloPath) {
            root
                .navigationTitle("Halo")
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .navigationDestination(for: HaloRoute.self) { route in
                    HaloDestination(route: route)
                        .toolbarBackground(Theme.bg, for: .navigationBar)
                }
        }
    }

    @ViewBuilder private var root: some View {
        if let controller = connection.controller {
            HaloHomeView(controller: controller)
                .id(ObjectIdentifier(controller))
        } else if connection.hasSavedHalo {
            HaloOfflineView()
        } else {
            ScanView()
        }
    }
}

// MARK: - Destinations

/// Resolves a `HaloRoute` to its screen.
struct HaloDestination: View {
    let route: HaloRoute
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        switch route {
        case .settings:
            SettingsView()
        case .advanced:
            AdvancedSettingsView()
        case .rename:
            ControllerGate { RenameHaloView(controller: $0) }
        case .pair:
            ScanView(onPaired: { router.showHaloHome() })
                .navigationTitle("Pair a Halo")
        case .ringWidgets:
            RingWidgetsView()
        case .display:
            ControllerGate { DisplayView(controller: $0).haloListStyle() }
        case .fitness:
            ControllerGate { FitnessView(controller: $0).haloListStyle() }
        case .soundTouch:
            ControllerGate { SoundTouchView(controller: $0) }
        case .liveLog:
            LiveLogScreen()
        case .login:
            LoginView { settings.useServer = true }
                .haloListStyle()
        case .rides:
            RidesView()
                .navigationTitle("Rides history")
                .haloListStyle()
        }
    }
}

/// Shows `content` with the live controller, or an empty state when no Halo is around.
struct ControllerGate<Content: View>: View {
    @EnvironmentObject private var connection: HaloConnection
    @ViewBuilder let content: (DeviceController) -> Content

    var body: some View {
        if let controller = connection.controller {
            content(controller)
        } else {
            EmptyState(systemImage: "circle.dashed",
                       title: "No Halo connected",
                       message: "Pair or reconnect your Halo first.")
                .haloScreenBackground()
        }
    }
}

extension View {
    /// Themed `List`/`Form`: hides the system grouped background behind the Halo `bg`.
    func haloListStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }
}

// MARK: - Home (a controller exists: connected, connecting, dropped or needing re-pair)

/// Option C of the Halo v2 design: a compact header (ring mirror, name, state, battery,
/// temperature) and three sections — Controls, Ring cards, Taps.
struct HaloHomeView: View {
    @ObservedObject var controller: DeviceController
    @EnvironmentObject private var connection: HaloConnection
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter

    enum HaloSection: String, CaseIterable, Identifiable {
        case controls, cards, taps
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .controls: return "Controls"
            case .cards: return "Ring cards"
            case .taps: return "Taps"
            }
        }
    }

    @AppStorage("sh2.halo.section") private var section: HaloSection = .controls
    @State private var showLightSheet = false
    @State private var showTapCode = false
    @State private var askForTapCode = false
    @State private var lightTick = 0
    @State private var alarmBusy = false
    @State private var preview: RingCard?
    @State private var previewTask: Task<Void, Never>?

    private var isReady: Bool { connection.state == .connected && controller.phase == .ready }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HaloHero(name: name, state: connection.state, lightOn: controller.lightOn,
                         brightness: controller.brightness / 255, blinking: controller.blinking,
                         armed: settings.alarmOn && settings.alarmTapCode != nil,
                         card: isReady ? preview : nil, controller: controller)
                LowBatteryBanner(controller: controller)
                stateAction
                Picker("Section", selection: $section) {
                    ForEach(HaloSection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch section {
                case .controls: controls
                case .cards: RingCardsSection(controller: controller, isReady: isReady, onShow: showPreview)
                case .taps: TapsSection(controller: controller, showTapCode: $showTapCode)
                }
                if controller.isDemo {
                    Label("Demo: Settings › Advanced › Simulate alarm walks away, moves the bike and comes back.",
                          systemImage: "wand.and.stars")
                        .font(.footnote)
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, Theme.Space.xs)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .haloScreenBackground()
        .sheet(isPresented: $showLightSheet) {
            LightSheet(controller: controller)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.surface2)
                .haloTheme()
        }
        .sheet(isPresented: $showTapCode) {
            TapCodeSheet(controller: isReady ? controller : nil)
            .presentationDetents([.large])
            .presentationBackground(Theme.surface2)
            .environmentObject(settings)
            .environmentObject(connection)
            .haloTheme()
        }
        .confirmationDialog("Set a tap code first", isPresented: $askForTapCode, titleVisibility: .visible) {
            Button("Set my tap code") { showTapCode = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please set a tap code before turning the alarm on. It lets you disarm the alarm on the Halo should your phone run out of battery.")
        }
        .sensoryFeedback(.success, trigger: settings.alarmOn) { old, new in !old && new }
        .sensoryFeedback(.impact(weight: .medium), trigger: lightTick)
    }

    private var name: String {
        connection.displayName ?? String(localized: "My Halo")
    }

    private func showPreview(_ card: RingCard) {
        controller.showCard(card)
        preview = card
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { preview = nil }
        }
    }

    // MARK: State-dependent action (reconnect / re-pair)

    @ViewBuilder private var stateAction: some View {
        switch connection.state {
        case .connected:
            EmptyView()
        case .connecting:
            HStack(spacing: Theme.Space.s) {
                ProgressView()
                Text("Connecting…").foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        case .disconnected:
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button { connection.retry() } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(WarnButtonStyle())
                if case .error(let message) = controller.phase {
                    Text(verbatim: message).font(.caption).foregroundStyle(Theme.textDim)
                } else {
                    Text("It reconnects automatically when the Halo is in range.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        case .needsRecovery:
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button { router.openRecovery() } label: {
                    Label("Re-pair", systemImage: "key.horizontal")
                }
                .buttonStyle(WarnButtonStyle())
                Text("This Halo doesn't accept this iPhone's password yet. Re-pair it to take control.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: Theme.Space.m) {
            ToggleRow(title: controller.lightOn ? LocalizedStringKey("Light on") : LocalizedStringKey("Light off"),
                      systemImage: controller.lightOn ? "lightbulb.fill" : "lightbulb",
                      detail: isReady ? lightDetail : String(localized: disabledNote),
                      isOn: controller.lightOn,
                      isEnabled: isReady,
                      secondary: .init(systemImage: "slider.horizontal.3", label: "Brightness and mode",
                                       action: { showLightSheet = true })) {
                lightTick += 1
                let on = !controller.lightOn
                Task { await controller.setLight(on: on) }
            }
            .accessibilityHint(Text("Turns the front light on or off"))

            ToggleRow(title: alarmOn ? LocalizedStringKey("Alarm on") : LocalizedStringKey("Alarm off"),
                      systemImage: alarmOn ? "lock.fill" : "lock.open",
                      detail: alarmDetail,
                      isOn: alarmOn,
                      isEnabled: isReady,
                      isBusy: alarmBusy) {
                toggleAlarm()
            }
            .accessibilityHint(Text(alarmOn ? LocalizedStringKey("Turns the alarm off")
                                            : LocalizedStringKey("Turns the alarm on")))

            // With the alarm off, "didn't go off" would suggest it was watching: only when it was on
            // (or something did set it off).
            if isReady, let report = controller.lastAlarmReport, alarmOn || report.triggerCount > 0 {
                AlarmRecap(count: report.triggerCount)
            }

            LowBatteryAlertRow()
        }
    }

    private var alarmOn: Bool { settings.alarmOn && settings.alarmTapCode != nil }

    private var disabledNote: LocalizedStringResource {
        connection.state == .needsRecovery ? "Re-pair to use" : "Reconnect to use"
    }

    private var lightDetail: String {
        let pct = (controller.brightness / 255).formatted(.percent.precision(.fractionLength(0)))
        let mode = controller.blinking ? String(localized: "Blinking") : String(localized: "Steady")
        return "\(pct) · \(mode)"
    }

    private var alarmDetail: String {
        guard isReady else { return String(localized: disabledNote) }
        if settings.alarmTapCode == nil { return String(localized: "Set a tap code to turn it on") }
        if alarmOn {
            if !controller.alarmSynced { return String(localized: "Couldn't update the Halo — tap to retry") }
            return String(localized: "Arms as soon as you leave your bike")
        }
        return String(localized: "Off")
    }

    private func toggleAlarm() {
        if settings.alarmTapCode == nil { askForTapCode = true; return }
        // ON but not applied (the Halo rejected it): retry instead of turning it off.
        let on = alarmOn && controller.alarmSynced ? false : true
        Task { await setAlarm(on: on) }
    }

    private func setAlarm(on: Bool) async {
        alarmBusy = true
        await controller.setAlarm(on: on)
        alarmBusy = false
    }
}

/// The official app's alarm recap, from the report read on connecting: "While you were away, your
/// alarm went off N times."
struct AlarmRecap: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("Recap")
                .font(.caption.weight(.heavy))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textDim)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(count > 0 ? Theme.warn : Theme.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var text: LocalizedStringKey {
        switch count {
        case 0: return "While you were away, your alarm didn't go off."
        case 1: return "While you were away, your alarm went off **once**."
        case 2: return "While you were away, your alarm went off **twice**."
        default: return "While you were away, your alarm went off **\(count) times**."
        }
    }
}

/// Red strip while the Halo's battery is low and it isn't charging.
struct LowBatteryBanner: View {
    @ObservedObject var controller: DeviceController

    var body: some View {
        if let level = controller.batteryLevel, level <= DeviceController.LowBattery.threshold,
           !controller.charging {
            Label {
                Text("Battery \(level)% — charge the Halo soon")
            } icon: {
                Image(systemName: "battery.25percent")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.danger)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1))
        }
    }
}

/// Settings toggle for the low-battery notification, styled as a Halo row.
struct LowBatteryAlertRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.lowBatteryAlert },
            set: { on in
                settings.lowBatteryAlert = on
                if on { Task { await AlarmNotifier.shared.requestAuthorization() } }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Low battery alert").font(.body.weight(.semibold))
                Text("Notify me at \(DeviceController.LowBattery.threshold)% or less")
                    .font(.footnote).foregroundStyle(Theme.textDim)
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 60)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
    }
}


// MARK: - Ring cards

/// The carousel cards rehalo feeds: a switch adds or removes each one from the Halo; tapping a
/// row shows that card on the Halo now (and previews it on the ring mirror).
struct RingCardsSection: View {
    @ObservedObject var controller: DeviceController
    let isReady: Bool
    let onShow: (RingCard) -> Void
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(spacing: 0) {
                ForEach(Array(RingCard.allCases.enumerated()), id: \.element) { index, card in
                    if index > 0 { Divider().overlay(Theme.stroke) }
                    row(card)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            Text("Swipe the Halo's top sideways to switch cards. Tap a card to show it now. Ride cards use the iPhone's GPS: open rehalo before you set off.")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, Theme.Space.xs)
        }
    }

    private func isOn(_ card: RingCard) -> Bool { settings.ringCards & card.card.bit != 0 }

    private func row(_ card: RingCard) -> some View {
        let on = isOn(card)
        let isLast = on && RingCard.allCases.filter(isOn).count == 1
        return HStack(spacing: Theme.Space.m) {
            Button { onShow(card) } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: card.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(on ? Theme.accent : Theme.textDim)
                        .frame(width: 28)
                    Text(card.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: Theme.Space.s)
                    Text(verbatim: value(card))
                        .font(Theme.metricFont(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isReady)
            .accessibilityHint(Text("Shows this card on the Halo now"))
            Toggle("", isOn: Binding(
                get: { on },
                set: { new in
                    settings.ringCards = new ? settings.ringCards | card.card.bit : settings.ringCards & ~card.card.bit
                    if isReady { Task { await controller.applyRingCards() } }
                }
            ))
            .labelsHidden()
            .tint(Theme.accent)
            .disabled(isLast)
            .accessibilityLabel(Text(card.label))
        }
        .padding(.horizontal, Theme.Space.l)
    }

    private func value(_ card: RingCard) -> String {
        switch card {
        case .clock: return Date().formatted(date: .omitted, time: .shortened)
        case .battery: return controller.batteryLevel.map { "\($0)%" } ?? "—"
        default: return String(localized: "While riding")
        }
    }
}

// MARK: - Taps

/// Tap shortcuts on the Halo (the official app's touch inputs) and the alarm's tap code.
struct TapsSection: View {
    @ObservedObject var controller: DeviceController
    @Binding var showTapCode: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(spacing: 0) {
                codeRow("• •") {
                    Text("Light on / off").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("Built in").font(.subheadline).foregroundStyle(Theme.textDim)
                }
                ForEach(TapAction.codes, id: \.self) { code in
                    Divider().overlay(Theme.stroke)
                    codeRow(symbols(code)) {
                        Menu {
                            Picker("Action", selection: Binding(
                                get: { settings.tapShortcuts[code] ?? .nothing },
                                set: { settings.tapShortcuts[code] = $0 }
                            )) {
                                ForEach(TapAction.allCases) { Text($0.label).tag($0) }
                            }
                        } label: {
                            HStack {
                                Text((settings.tapShortcuts[code] ?? .nothing).label)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(Theme.textDim)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            Text("• short tap, — long press, on the Halo's top while it's connected to this iPhone. A single tap is the easiest to make by accident.")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, Theme.Space.xs)

            Button { showTapCode = true } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "lock")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alarm tap code").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("Arms or disarms the alarm on the Halo, without your iPhone")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Text(verbatim: settings.alarmTapCode?.symbols ?? "—")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, Theme.Space.l)
                .frame(minHeight: 64)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .padding(.top, Theme.Space.s)
        }
    }

    private func symbols(_ code: String) -> String {
        code.map { $0 == "l" ? "—" : "•" }.joined(separator: " ")
    }

    private func codeRow<Content: View>(_ code: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(verbatim: code)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, alignment: .leading)
            content()
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 56)
    }
}

// MARK: - Offline (a Halo is saved but not reachable / not known to CoreBluetooth yet)

struct HaloOfflineView: View {
    @EnvironmentObject private var connection: HaloConnection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HaloHero(name: connection.displayName ?? String(localized: "My Halo"),
                         state: connection.state)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Button { connection.retry() } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(WarnButtonStyle())
                    Text("Turn on Bluetooth and wake the Halo (tap it or plug it in). If it still doesn't show up, pair it again.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
                VStack(spacing: 0) {
                    NavigationLink(value: HaloRoute.pair) {
                        HaloLinkRow(title: "Pair again", systemImage: "plus.circle")
                    }
                }
                .buttonStyle(.plain)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .haloScreenBackground()
    }
}

// MARK: - Pieces

/// Compact header: live ring mirror; name, connection state and the Halo's own figures (battery,
/// temperature) beside it; Settings top-trailing.
struct HaloHero: View {
    let name: String
    let state: HaloConnectionState
    var lightOn = false
    var brightness: Double = 0.5
    var blinking = false
    var armed = false
    var card: RingCard? = nil
    var controller: DeviceController? = nil

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            RingMirror(state: state, lightOn: lightOn, brightness: brightness, blinking: blinking,
                       armed: armed, card: card, batteryLevel: controller?.batteryLevel,
                       charging: controller?.charging ?? false, size: 132)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: name)
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(stateLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                }
                .accessibilityElement(children: .combine)
                if let controller { HaloStats(controller: controller, live: state == .connected) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, Theme.minTarget)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            Button { router.haloPath.append(.settings) } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: Theme.minTarget, height: Theme.minTarget)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text("Settings"))
        }
    }

    private var color: Color {
        switch state {
        case .connected: return Theme.accent
        case .connecting, .needsRecovery: return Theme.warn
        case .disconnected: return Theme.textDim
        }
    }

    private var stateLabel: LocalizedStringKey {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .needsRecovery: return "Needs re-pairing"
        }
    }
}

/// Battery (+ charging) and device temperature, from the Halo's own reports.
/// Offline, the last known battery is shown dimmed with its age.
struct HaloStats: View {
    @ObservedObject var controller: DeviceController
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let level = controller.batteryLevel {
                Button { Task { await controller.showCharge() } } label: {
                    Label { Text(verbatim: batteryText(level)) } icon: { Image(systemName: batteryIcon(level)) }
                        .foregroundStyle(level <= DeviceController.LowBattery.threshold && !controller.charging
                                         ? Theme.danger : (live ? Theme.text : Theme.textDim))
                }
                .disabled(!live)
                .accessibilityHint(Text("Shows the charge on the Halo"))
            }
            if live, let temp = controller.temperature {
                Label {
                    Text(Measurement(value: Double(temp), unit: UnitTemperature.celsius)
                        .formatted(.measurement(width: .abbreviated, usage: .weather)))
                } icon: { Image(systemName: "thermometer.medium") }
                    .foregroundStyle(temp >= 45 ? Theme.warn : Theme.text)
                    .accessibilityLabel(Text("Device temperature \(temp) degrees"))
            }
        }
        .font(Theme.metricFont(.subheadline, weight: .semibold))
        .buttonStyle(.plain)
    }

    private func batteryText(_ level: Int) -> String {
        var text = "\(level)%"
        if controller.charging { text += " · " + String(localized: "Charging") }
        if !live, let at = controller.batteryUpdatedAt {
            text += " · " + at.formatted(.relative(presentation: .named))
        }
        return text
    }

    private func batteryIcon(_ level: Int) -> String {
        if controller.charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// One row of the Halo tab's link list.
struct HaloLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var value: String? = nil
    var badge: LocalizedStringKey? = nil

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .frame(width: 24)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Space.s)
            if let value {
                Text(verbatim: value)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            if let badge { SoonBadge(text: badge) }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

/// Small grey "SOON" (post-MVP) badge.
struct SoonBadge: View {
    var text: LocalizedStringKey = "SOON"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.textDim, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(Text("Coming soon"))
    }
}

/// Amber "Reconnect / Re-pair" button (UX §6: warn = reconnecting, recovery).
struct WarnButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.warn)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.warn.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.45), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

// MARK: - Light sheet

/// Brightness slider + steady / blinking (existing `DeviceController` light APIs).
struct LightSheet: View {
    @ObservedObject var controller: DeviceController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            Text("Front light")
                .font(.title2.weight(.heavy))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { controller.lightOn },
                set: { on in Task { await controller.setLight(on: on) } }
            )) {
                Text("On").font(.body.weight(.semibold))
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: controller.lightOn)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Brightness").font(.body.weight(.semibold))
                    Spacer()
                    Text(verbatim: (controller.brightness / 255)
                        .formatted(.percent.precision(.fractionLength(0))))
                        .font(Theme.metricFont(.body))
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: $controller.brightness, in: 13...255, step: 1) { editing in
                    if !editing { Task { await controller.applyLightSettings() } }
                }
                .accessibilityLabel(Text("Brightness"))
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Mode").font(.body.weight(.semibold))
                Picker("Mode", selection: Binding(
                    get: { controller.blinking },
                    set: { controller.blinking = $0; Task { await controller.applyLightSettings() } }
                )) {
                    Text("Steady").tag(false)
                    Text("Blinking").tag(true)
                }
                .pickerStyle(.segmented)
            }

            PrimaryButton("Done") { dismiss() }
        }
        .padding(Theme.Space.xl)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Ring & widgets (post-MVP hub; existing screens, themed only)

struct RingWidgetsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: HaloRoute.display) {
                    Label("Display & ring widgets", systemImage: "circle.hexagongrid")
                }
                NavigationLink(value: HaloRoute.fitness) {
                    Label("Fitness goal & progress ring", systemImage: "figure.outdoor.cycle")
                }
            } footer: {
                Text("Coming soon: a redesigned ring editor with a live preview. These are the current tools.")
            }
            .listRowBackground(Theme.surface)
        }
        .haloListStyle()
        .navigationTitle("Ring & widgets")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Live log screen

struct LiveLogScreen: View {
    var body: some View {
        ScrollView {
            LogConsoleView(height: 520)
                .padding(Theme.Space.l)
        }
        .haloScreenBackground()
        .navigationTitle("Live log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
