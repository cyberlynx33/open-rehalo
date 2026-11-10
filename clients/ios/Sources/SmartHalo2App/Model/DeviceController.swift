import Foundation
import SH2Protocol

/// View-model that drives a single device session: connect → authenticate (or recover) → control.
/// All state is published on the main actor for SwiftUI.
@MainActor
final class DeviceController: ObservableObject {

    enum Phase: Equatable {
        case connecting
        case authenticating
        case needsRecovery          // the ring rejected every stored password and the empty one
        case recovering
        case needsReboot            // un-pair done; the ring must power-cycle to finish (see recover())
        case ready
        case disconnected           // the link dropped (or was cancelled); `HaloConnection` reconnects
        case error(String)
    }

    // Connection / auth
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var statusMessage: String = ""
    /// Freshly generated password after a successful recovery — shown once so the user can note it.
    @Published private(set) var newlyGeneratedPassword: String?

    // Controls
    @Published var lightOn = false
    /// The ring's carousel card, as it last reported it (BLE notification 5,2); 0 = Navigation.
    @Published private(set) var carouselCard: UInt8?
    @Published var brightness: Double = 128      // 0...255
    @Published var blinking = false
    /// The Halo's alarm configuration was last applied OK on this connection (`alarmConfigure`).
    @Published private(set) var alarmSynced = false
    /// Last parsed `alarmReport` {3,0}, read on every connection: its `triggerCount` is the
    /// official app's recap ("while you were away, your alarm went off N times").
    @Published private(set) var lastAlarmReport: AlarmReport?

    // Battery & temperature (getState {4,1} on connect, then the ring's UP report every ~60 s).
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var charging = false
    @Published private(set) var plugged = false
    /// The accelerometer's die temperature, °C (reads a few degrees above ambient).
    @Published private(set) var temperature: Int?
    /// When the battery figures were last reported (shown while offline as "last seen").
    @Published private(set) var batteryUpdatedAt: Date?

    // Info
    @Published private(set) var firmwareVersion: String = "—"
    @Published private(set) var bootloaderVersion: String = "—"
    @Published private(set) var serial: String = "—"
    @Published private(set) var alarmReportHex: String = "—"
    @Published private(set) var deviceStateHex: String = "—"
    @Published var deviceName: String = ""

    let device: DiscoveredDevice
    private let central: BluetoothCentral
    private var deviceID: String { device.id.uuidString }

    /// Non-nil → demo mode (a fake `MockTransport` instead of a real BLE connection).
    private let demoTransport: Transport?
    var isDemo: Bool { demoTransport != nil }

    private var transport: Transport?
    private var session: Session?
    /// The session once the ring has accepted a password. Commands go through this one: sent
    /// during a handshake or a recovery, a command would take the session's single request slot
    /// between two of its steps and make that step fail.
    private var readySession: Session? { phase == .ready ? session : nil }
    /// Bumped by every `start()` and `close()`: a `start()` that fails only lets go of the link if
    /// no newer `start()`/`close()` has taken it over meanwhile.
    private var linkGeneration = 0
    /// Re-applies the rider's card mask after a "show now" of a hidden card.
    private var cardMaskRestore: Task<Void, Never>?
    /// Demo only: a simulated "password rejected" is pending (`simulateNeedsRecovery()`), so
    /// `recover()` / `reconnectAndFinish()` play the recovery wizard's steps without Bluetooth.
    private var demoRecoveryPending = false

    init(device: DiscoveredDevice, central: BluetoothCentral, demoTransport: Transport? = nil) {
        self.device = device
        self.central = central
        self.demoTransport = demoTransport
        loadBatteryCache()
    }

    // MARK: - Lifecycle

    /// Connect and authenticate. `only` tries that password alone (Settings › Advanced › Enter a
    /// saved password); otherwise every password this iPhone has for the ring is tried (see
    /// `authenticate`).
    func start(only typed: String? = nil) async {
        linkGeneration &+= 1
        let generation = linkGeneration
        do {
            phase = .connecting
            statusMessage = "Connecting…"

            // Demo mode: a fake device over a MockTransport — skip Bluetooth, auth and recovery.
            if let demoTransport {
                SH2Log.log("DEMO: simulated SmartHalo (no Bluetooth, no recovery)")
                self.transport = demoTransport
                let session = Session(transport: demoTransport)
                self.session = session
                try await session.open()
                await session.authenticateForDemo()
                deviceName = device.name
                await finishReady()
                return
            }

            let transport: BluetoothTransport
            do {
                transport = try await central.connect(device)
            } catch BluetoothCentral.CentralError.superseded {
                return                      // a newer start() owns the phase now
            } catch BluetoothCentral.CentralError.cancelled {
                phase = .disconnected
                statusMessage = ""
                return
            }
            self.transport = transport

            let session = Session(transport: transport)
            self.session = session
            try await session.open()

            phase = .authenticating
            statusMessage = "Authenticating…"
            let accepted = try await authenticate(session, only: typed)
            // A close() or a newer start() took over meanwhile: the phase is theirs.
            guard generation == linkGeneration else { return }
            if accepted {
                await finishReady()
            } else {
                statusMessage = KeychainStore.load(deviceID: deviceID) == nil
                    ? "No saved password for this device. Recovery required."
                    : "Saved password rejected. Recovery required."
                phase = .needsRecovery
            }
        } catch {
            guard generation == linkGeneration else { return }
            // A timeout, a dropped link, a reply that doesn't decode: nothing to do with the
            // password, so no recovery. Let go of the link (the ring only forgets a half-done
            // handshake when the link drops); `HaloConnection` reconnects with backoff.
            SH2Log.log("connection: \(describe(error)) — will retry")
            if !isDemo { close() }
            phase = .error(describe(error))
        }
    }

    /// Authenticate over a fresh link. Tries, in order: this iPhone's password for the ring, the
    /// one it replaced, those stored for other peripheral identifiers (another iPhone's, synced
    /// through iCloud Keychain) and the empty password. True once the ring accepted one; false only
    /// when it answered `RET_FAIL` to all of them, the one case that needs a recovery. Link
    /// failures throw.
    ///
    /// The ring checks against the password it loaded from flash at boot (`auth_init`), and the
    /// STM32 power-cycles the BLE chip on every boot and standby change, so a ring can come back
    /// without the password it accepted before:
    /// - none, after `resetPassword` (it clears flash only) and a reboot. The empty password gets
    ///   in, and the ring gets this iPhone's password back: no reset, no reboot, same password;
    /// - an older one, when it acknowledged a `setPassword` whose flash write was dropped (`rec_write`
    ///   gives up when its queue is full or flash stays full after GC). The previous one gets in.
    ///
    /// The keys of the last handshake are kept so a relaunched app can take over the link a killed
    /// one left up: the ring still encrypts with them (`Session.establishLink(resuming:)`).
    private func authenticate(_ session: Session, only typed: String?) async throws -> Bool {
        let sync = AppSettings.shared.syncPasswordsToICloud
        let previous = KeychainStore.loadLinkKeys(deviceID: deviceID).flatMap { Crypto.LinkKeys(secret: $0) }
        let keys = try await session.establishLink(resuming: previous)
        KeychainStore.saveLinkKeys(keys.secret, deviceID: deviceID)

        if let typed {
            guard try await session.authenticate(password: Data(typed.utf8)) else { return false }
            try? KeychainStore.save(password: typed, deviceID: deviceID, synchronizable: sync)
            return true
        }

        let saved = KeychainStore.load(deviceID: deviceID)
        if let saved, try await session.authenticate(password: Data(saved.utf8)) { return true }

        // Capped: each try is one round trip, and a keychain full of stale entries shouldn't stall
        // the connection.
        for candidate in KeychainStore.fallbackPasswords(deviceID: deviceID).prefix(5) {
            statusMessage = "Trying an earlier password…"
            guard try await session.authenticate(password: Data(candidate.utf8)) else { continue }
            try? KeychainStore.save(password: candidate, deviceID: deviceID, synchronizable: sync)
            SH2Log.log("auth: the ring took an earlier stored password — keeping it")
            return true
        }

        guard try await session.authenticate(password: Data()) else { return false }
        statusMessage = "Re-pairing…"
        let password = reusablePassword(saved) ?? Recovery.generateDevicePassword()
        // Stored before the ring has it: if the reply is lost, the next connection still has it.
        try KeychainStore.save(password: password, deviceID: deviceID, synchronizable: sync)
        try await Recovery.setPassword(session: session, password)
        if password == saved {
            SH2Log.log("auth: the ring had no password (un-paired) — gave it back this iPhone's")
        } else {
            SH2Log.log("auth: the ring had no password (un-paired) — paired it with a new one")
            newlyGeneratedPassword = password
        }
        return true
    }

    /// `saved` if the firmware can store it as is (`auth_setPassword` takes 32 bytes).
    private func reusablePassword(_ saved: String?) -> String? {
        guard let saved, saved.utf8.count == 32 else { return nil }
        return saved
    }

    /// Run the reset-challenge + re-pair recovery flow. The ring gets the password this iPhone
    /// already has for it, if any (other iPhones and password managers that know it keep working),
    /// or a new one.
    ///
    /// Two phases, because of a firmware quirk: `resetPassword` clears the stored password in flash,
    /// but the device keeps the OLD password in RAM until it next boots (`auth_init` only loads it at
    /// boot). So on a still-running paired ring, the empty-password re-pair fails — we detect that and
    /// ask the user to power-cycle the ring, then finish via `reconnectAndFinish()`.
    func recover() async {
        if isDemo { await demoRecover(); return }
        guard let session else { return }
        do {
            phase = .recovering
            // 1. Un-pair (clears the stored password in flash). Idempotent — safe to repeat.
            statusMessage = "Un-pairing (reset-challenge)…"
            try await Recovery.resetPairing(session: session)
            // 2. Re-pair (only works once the ring has rebooted). The password is stored first, so
            //    the ring never ends up with one this iPhone doesn't have; after the reboot,
            //    `start()` hands it to the un-paired ring.
            statusMessage = "Re-pairing…"
            let saved = KeychainStore.load(deviceID: deviceID)
            let password = reusablePassword(saved) ?? Recovery.generateDevicePassword()
            try KeychainStore.save(password: password, deviceID: deviceID,
                                   synchronizable: AppSettings.shared.syncPasswordsToICloud)
            do {
                try await Recovery.repair(session: session, newPassword: password)
                if let keys = await session.linkKeys { KeychainStore.saveLinkKeys(keys.secret, deviceID: deviceID) }
                if password != saved { newlyGeneratedPassword = password }
                await finishReady()
            } catch let e as Session.SessionError {
                // Empty-password authenticate answered RET_FAIL → the ring still holds its old
                // password in RAM → it must reboot. Anything else (an empty reply, DENIED, a link
                // error) says nothing about the password and is a genuine error: "Try again".
                if case .commandFailed(let step, let code) = e, step == "authenticate",
                   code == ReturnCode.fail.rawValue {
                    statusMessage = "Un-paired ✓ — the ring must reboot once to finish."
                    phase = .needsReboot
                } else {
                    throw e
                }
            }
        } catch {
            phase = .error(describe(error))
        }
    }

    /// Finish the recovery after the user has power-cycled the ring: reconnect to the (now rebooted)
    /// device. After a reboot the firmware has reloaded an empty password, so `start()` finds it
    /// un-paired and gives it the password `recover()` stored. If it hasn't rebooted, the recovery
    /// runs again and asks for the reboot again.
    func reconnectAndFinish() async {
        if isDemo { await demoFinishRecovery(); return }
        await restart()
        if case .needsRecovery = phase {
            await recover()
        }
    }

    /// Let go of the current link (or pending connect) and connect again from scratch. The pause
    /// lets CoreBluetooth report the old link's disconnect before the new connect is registered.
    /// `start()` is not reentrant: a `start()` over a link that is being set up would give one link
    /// two owners, so a retry during `.connecting`/`.authenticating` comes through here.
    func restart(only typed: String? = nil) async {
        close()
        try? await Task.sleep(for: .seconds(1))
        await start(only: typed)
    }

    private func finishReady() async {
        phase = .ready
        statusMessage = "Connected."
        if let session { await installUpHandler(session) }
        await refreshInfo()
        await refreshDeviceState()
        await syncAlarm()
        await applyRingCards()
    }

    func close() {
        linkGeneration &+= 1
        alarmSynced = false
        callAlertActive = false
        Task { await session?.close() }
        central.disconnect()
    }

    /// The BLE link dropped underneath us: drop the dead session so the next `start()` builds a
    /// fresh one. Called by `HaloConnection` on an unexpected disconnect.
    func markDisconnected() {
        guard !isDemo else { return }
        let old = session
        session = nil
        transport = nil
        alarmSynced = false
        callAlertActive = false
        Task { await old?.close() }
        phase = .disconnected
        statusMessage = ""
    }

    // MARK: - Controls
    //
    // All control methods are @MainActor (the whole class is). `session.transceive(...)` hops onto
    // the Session actor to do the BLE round-trip and hops back here on return, so `@Published`
    // state is always assigned on the main actor. Command payloads are sent encrypted by default
    // (the session has a cipher after the handshake). The session queues requests: a tap on the
    // light while the guidance or the carousel's answer is in flight waits its turn, it isn't lost.

    func setLight(on: Bool) async {
        guard let session = readySession else { return }
        do {
            _ = try await session.transceive(Commands.frontLight(on: on))
            lightOn = on
        } catch { statusMessage = "front light failed: \(describe(error))" }
    }

    func applyLightSettings() async {
        guard let session = readySession else { return }
        let mode: Commands.LightMode = blinking ? .blinking : .normal
        let level = UInt8(max(0, min(255, brightness.rounded())))
        do {
            _ = try await session.transceive(Commands.frontLightSettings(mode: mode, brightness: level))
        } catch { statusMessage = "light settings failed: \(describe(error))" }
    }

    // MARK: - Ring effects (animations) + device settings

    func showClockNow() async {
        guard let session = readySession else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let cmd = Commands.showClock(hour: UInt8(c.hour ?? 0), minute: UInt8(c.minute ?? 0))
        do { _ = try await session.transceive(cmd, label: "showClock") }
        catch { statusMessage = "clock failed: \(describe(error))" }
    }

    func showSpeedometerDemo() async {
        guard let session = readySession else { return }
        do { _ = try await session.transceive(Commands.showSpeedometer(percentage: 60, speed: 24), label: "speedometer") }
        catch { statusMessage = "speedometer failed: \(describe(error))" }
    }

    func showCharge() async {
        guard let session = readySession else { return }
        do { _ = try await session.transceive(Commands.showStateOfCharge(), label: "showCharge") }
        catch { statusMessage = "charge anim failed: \(describe(error))" }
    }

    func animationsOff() async {
        guard let session = readySession else { return }
        do { _ = try await session.transceive(Commands.animOff(), label: "animOff") }
        catch { statusMessage = "anim off failed: \(describe(error))" }
    }

    /// Fire a display/ring command (fire-and-forget; errors surface in statusMessage + the live log).
    func run(_ cmd: Data, _ label: String) async {
        guard let session = readySession else { return }
        do { _ = try await session.transceive(cmd, label: label) }
        catch { statusMessage = "\(label) failed: \(describe(error))" }
    }

    // M1 — display widgets / assistant
    func showLogo() async            { await run(Commands.logo(), "logo") }
    func showDemo() async            { await run(Commands.demo(), "demo") }
    func showCompass(heading: UInt16) async { await run(Commands.compass(heading: heading), "compass") }
    func compassOff() async          { await run(Commands.compassOff(), "compassOff") }
    func showProgress(_ pct: UInt8) async   { await run(Commands.progress(percentage: pct), "progress") }
    func progressOff() async         { await run(Commands.progressOff(), "progressOff") }
    func showHeartbeat() async       { await run(Commands.heartbeat(), "heartbeat") }
    func heartbeatOff() async        { await run(Commands.heartbeatOff(), "heartbeatOff") }
    func showLowBattery() async      { await run(Commands.lowBattery(), "lowBattery") }
    func clockOff() async            { await run(Commands.clockOff(), "clockOff") }
    func speedometerOff() async      { await run(Commands.speedometerOff(), "speedometerOff") }
    func showSpeedometerIntro() async { await run(Commands.speedometerIntro(), "speedometerIntro") }
    func showFitnessIntro() async    { await run(Commands.fitnessIntro(), "fitnessIntro") }
    func setFrontExternal(on: Bool) async { await run(Commands.frontExternalToggle(on: on), "frontExternal") }
    func carouselGoto(_ i: UInt8) async { await run(Commands.carouselPosition(i), "carouselPosition") }

    @discardableResult
    func renameDevice() async -> Bool {
        guard let session = readySession, !deviceName.isEmpty else { return false }
        do {
            _ = try await session.transceive(Commands.setName(deviceName), label: "setName")
            statusMessage = "Renamed to “\(deviceName)”."
            return true
        } catch {
            statusMessage = "rename failed: \(describe(error))"
            return false
        }
    }

    /// Fetch the 4-byte alarm seed (`alarmGetSeed` {3,1}); `alarmConfigure` must carry it.
    private func alarmSeed() async -> Data? {
        guard let r = await transceiveRetrying(Commands.alarmGetSeed(), "alarmGetSeed") else { return nil }
        let b = [UInt8](r)
        guard b.count >= 5, b[0] == ReturnCode.ok.rawValue else { return nil }
        return Data(b[1..<5])
    }

    // MARK: - Alarm (as in the official app)
    //
    // The official app never sends `{3,2}`: it pushes the whole alarm configuration with
    // `configureAlarm` {3,3} — tap code, ON/OFF, sensitivity — on every connection and on every
    // change (`AlarmController.updateAlarmState`), and only keeps a change the Halo accepted. The
    // firmware only *watches* while no phone is connected (`AlarmTask.c`): with the alarm ON it
    // arms itself as soon as the link drops and the Halo isn't charging, sounds on persistent
    // movement, and disarms when a phone reconnects (or with the tap code on the Halo). So "ON"
    // means "arm when I walk away", nothing more.

    /// Push an alarm configuration to the Halo — the saved settings, or a change to try — and
    /// save the change only if the Halo accepted it. False if not connected or rejected.
    @discardableResult
    func applyAlarmConfig(on: Bool? = nil, tapCode: TapCode? = nil, vigilant: Bool? = nil) async -> Bool {
        let settings = AppSettings.shared
        // A rejected change leaves the Halo on its previous (synced) configuration.
        let isChange = on != nil || tapCode != nil || vigilant != nil
        let on = on ?? settings.alarmOn
        let code = tapCode ?? settings.alarmTapCode
        let vigilant = vigilant ?? settings.alarmVigilant
        let armed = on && code != nil
        guard readySession != nil, let seed = await alarmSeed() else {
            statusMessage = "alarm: couldn't get seed"
            if !isChange { alarmSynced = false }
            return false
        }
        let cmd = Commands.alarmConfigure(seed: seed, tapCode: code?.bits ?? 0, tapLength: code?.length ?? 0,
                                          armed: armed, vigilant: vigilant)
        guard let r = await transceiveRetrying(cmd, "alarmConfigure"),
              r.first == ReturnCode.ok.rawValue else {
            statusMessage = "alarm: the Halo rejected the configuration"
            if !isChange { alarmSynced = false }
            return false
        }
        SH2Log.log("alarm: \(armed ? "ON — arms when no phone is connected" : "OFF") · code \(code?.text ?? "none") · \(vigilant ? "vigilant" : "lenient")")
        if settings.alarmOn != on { settings.alarmOn = on }
        if settings.alarmTapCode != code { settings.alarmTapCode = code }
        if settings.alarmVigilant != vigilant { settings.alarmVigilant = vigilant }
        alarmSynced = true
        return true
    }

    /// Turn the alarm ON/OFF (needs a tap code to turn it on, like the official app).
    @discardableResult
    func setAlarm(on: Bool) async -> Bool {
        guard !on || AppSettings.shared.alarmTapCode != nil else { return false }
        return await applyAlarmConfig(on: on)
    }

    /// After connecting: read what happened while we were away, then re-apply our settings
    /// (`AlarmController.observeConnectionState` → `fetchAlarmReport` + `updateAlarmState`).
    private func syncAlarm() async {
        await fetchAlarmReport()
        await applyAlarmConfig()
    }

    /// Read `alarmReport` {3,0}. Every read zeroes the ring's counter; `recap: false` (the debug
    /// read in Advanced) leaves the recap of this connection alone.
    @discardableResult
    private func fetchAlarmReport(recap: Bool = true) async -> AlarmReport? {
        guard let r = await transceiveRetrying(Commands.alarmReport(), "alarmReport") else { return nil }
        let hex = r.dropFirst().map { String(format: "%02x", $0) }.joined(separator: " ")
        alarmReportHex = hex.isEmpty ? "(empty)" : hex
        guard let report = AlarmReport(reply: r) else { return nil }
        if recap { lastAlarmReport = report }
        if report.triggerCount > 0 { SH2Log.log("alarm: went off \(report.triggerCount)× while we were away") }
        return report
    }

    /// `transceive` on the ready session (requests queue up inside it). Nil on failure, with the
    /// error in `statusMessage`.
    private func transceiveRetrying(_ cmd: Data, _ label: String) async -> Data? {
        guard let session = readySession else { return nil }
        do {
            return try await session.transceive(cmd, label: label)
        } catch {
            statusMessage = "\(label) failed: \(describe(error))"
            return nil
        }
    }

    // MARK: - UP channel

    private func installUpHandler(_ session: Session) async {
        await session.setNotificationHandler { [weak self] data in
            let note = UpNotification(data)
            Task { @MainActor [weak self] in self?.handleUp(note) }
        }
    }

    private func handleUp(_ note: UpNotification) {
        // Any event from the ring may be what wakes a suspended app: catch up on the phone's calls.
        CallAlertController.shared.refresh()
        switch note {
        case .light(let isOn, _, _):
            lightOn = isOn
        case .carouselPosition(let card):
            carouselCard = card
            answerCard(card)
        case .deviceInfo(let soc, let temp, let isPlugged):
            if let soc {
                // This report has no charging flag: plugged in and not full = charging.
                let onPower = isPlugged ?? plugged
                updateBattery(level: soc, charging: onPower && soc < 100, plugged: onPower,
                              temperature: temp ?? temperature)
            } else {
                Task { await refreshDeviceState() }
            }
        case .touch(let code):
            handleTap(code)
        default:
            break
        }
    }

    // MARK: - Battery & temperature

    enum LowBattery {
        /// Notify at or below this level (%).
        static let threshold = 20
        /// Notify again only after charging or climbing back above this level.
        static let rearm = 30
    }

    private var batteryKey: String { "sh2.battery.\(deviceID)" }

    private func updateBattery(level: Int, charging: Bool, plugged: Bool, temperature: Int?) {
        batteryLevel = level
        self.charging = charging
        self.plugged = plugged
        self.temperature = temperature
        batteryUpdatedAt = Date()
        UserDefaults.standard.set(["level": level, "charging": charging, "plugged": plugged,
                                   "temp": temperature ?? Int.min, "at": Date().timeIntervalSince1970],
                                  forKey: batteryKey)
        checkLowBattery()
    }

    /// Last known battery, so the Halo tab has something to show before (or without) a connection.
    private func loadBatteryCache() {
        guard let c = UserDefaults.standard.dictionary(forKey: batteryKey),
              let level = c["level"] as? Int, let at = c["at"] as? Double else { return }
        batteryLevel = level
        charging = c["charging"] as? Bool ?? false
        plugged = c["plugged"] as? Bool ?? false
        temperature = (c["temp"] as? Int).flatMap { $0 == Int.min ? nil : $0 }
        batteryUpdatedAt = Date(timeIntervalSince1970: at)
    }

    /// One "battery low" notification per discharge: re-armed once it's charging or back above
    /// `LowBattery.rearm`.
    private func checkLowBattery() {
        guard let level = batteryLevel else { return }
        let key = batteryKey + ".lowNotified"
        let notified = UserDefaults.standard.bool(forKey: key)
        if charging || plugged || level > LowBattery.rearm {
            if notified { UserDefaults.standard.set(false, forKey: key) }
            return
        }
        guard level <= LowBattery.threshold, !notified, AppSettings.shared.lowBatteryAlert else { return }
        UserDefaults.standard.set(true, forKey: key)
        let name = deviceName.isEmpty ? device.name : deviceName
        AlarmNotifier.shared.postLowBattery(level: level, haloName: name)
    }

    // MARK: - Ring cards (carousel)

    /// The carousel mask: the rider's cards, plus Navigation while a route is being followed.
    var ringMask: UInt16 {
        AppSettings.shared.ringCards
            | (GuidanceController.shared.following ? Commands.CarouselCard.navigation.bit : 0)
    }

    /// Tell the Halo which cards to cycle through (without moving it).
    func applyRingCards() async {
        cardMaskRestore?.cancel()
        sendNav([NavCommand(data: Commands.carouselMask(ringMask), label: "carouselMask")])
    }

    /// Jump the Halo to `card` now. A hidden card is shown for a moment, then the mask is restored.
    func showCard(_ card: RingCard) {
        let mask = ringMask | card.card.bit
        sendNav([NavCommand(data: Commands.carouselPosition(card.card.rawValue, mask: mask), label: "carouselPosition")])
        cardMaskRestore?.cancel()
        guard mask != ringMask else { return }
        cardMaskRestore = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.sendNav([NavCommand(data: Commands.carouselMask(self.ringMask), label: "carouselMask")])
        }
    }

    /// The ring shows `card` and asks for its content (UP 5, every second while it's on screen):
    /// answer like the official `CarouselController.handleNewNotification`. Navigation (0) is
    /// `GuidanceController`'s.
    private func answerCard(_ index: UInt8) {
        guard let card = Commands.CarouselCard(rawValue: index), card != .navigation else { return }
        let mask = ringMask | card.bit
        let metric = AppSettings.shared.units == .metric
        let data: Data
        switch card {
        case .clock:
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let is24h = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
            data = Commands.carouselClock(mask: mask, hour: UInt8(c.hour ?? 0), minute: UInt8(c.minute ?? 0), is24h: is24h)
        case .battery:
            data = Commands.carouselBattery(mask: mask)
        case .speed, .distance, .time, .avgSpeed:
            let ride = RideMetrics.shared.snapshotForRing()
            switch card {
            case .speed: data = Commands.carouselSpeed(mask: mask, kmh: ride.speedKmh, metric: metric)
            case .distance: data = Commands.carouselDistance(mask: mask, metres: ride.metres, metric: metric)
            case .time: data = Commands.carouselTime(mask: mask, seconds: ride.seconds)
            default: data = Commands.carouselAvgSpeed(mask: mask, averageKmh: ride.averageKmh,
                                                      currentKmh: ride.speedKmh, metric: metric)
            }
        default:
            // Goal, calories, CO2: not fed by rehalo — keep the mask, the ring shows its defaults.
            data = Commands.carouselMask(mask)
        }
        sendNav([NavCommand(data: data, label: "carousel")], droppable: true)
    }

    // MARK: - Tap shortcuts

    /// A tap code on the Halo (UP 0). "ss" is the firmware's own light toggle. While the tap-code
    /// recorder is open, taps go to it only.
    private func handleTap(_ code: String) {
        if let tapCaptured { tapCaptured(code); return }
        if callAlertActive, code == "s" { silenceIncomingCall(); return }
        guard code != "ss", let action = AppSettings.shared.tapShortcuts[code] else { return }
        SH2Log.log("tap \(code) → \(action.rawValue)")
        switch action {
        case .horn: Task { await playHorn() }
        case .clock: Task { await showClockNow() }
        case .battery: Task { await showCharge() }
        case .light: Task { await setLight(on: !lightOn) }
        case .nothing: break
        }
    }

    /// Receives every tap code while set (the tap-code recorder in Settings › Alarm).
    var tapCaptured: ((String) -> Void)?

    func playHorn() async { await run(Commands.soundPlay(volume: 100, track: Commands.hornTrack), "horn") }

    // MARK: - Call alerts
    //
    // `CallAlertController` decides; this talks to the ring. Through the `sendNav` queue, so the
    // alert and its sound go out in order with the guidance's commands.

    /// The ring has been told about an incoming call and not yet told it's over.
    private(set) var callAlertActive = false

    func showIncomingCall(sound: Bool) {
        callAlertActive = true
        var commands = [NavCommand(data: Commands.incomingCall(text: String(localized: "Incoming call")),
                                   label: "incomingCall")]
        if sound { commands.append(NavCommand(data: Commands.callSound(), label: "callSound")) }
        sendNav(commands)
    }

    func clearIncomingCall() {
        callAlertActive = false
        sendNav([NavCommand(data: Commands.notificationOff(), label: "notificationOff"),
                 NavCommand(data: Commands.soundStop(), label: "soundStop")])
    }

    /// Stop the ringtone only; the ring keeps pulsing, like the official app.
    func silenceIncomingCall() {
        guard callAlertActive else { return }
        sendNav([NavCommand(data: Commands.soundStop(), label: "soundStop")])
    }

    // MARK: - Rain alerts

    /// Show the rain warning, then release the ring: left alone, the firmware would keep the turn
    /// guidance off for twice the warning's length. A call takes over and clears the ring itself.
    func showRainAlert(text: String) {
        guard !callAlertActive else { return }
        sendNav([NavCommand(data: Commands.rainAlert(text: text), label: "rainAlert"),
                 NavCommand(data: Commands.soundPlay(volume: 50, track: Commands.NavSound.info), label: "rainSound")])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !self.callAlertActive else { return }
            self.sendNav([NavCommand(data: Commands.notificationOff(), label: "notificationOff")])
        }
    }

    // MARK: - Demo recovery (M11)
    //
    // The mock ring skips the real handshake, so the recovery wizard can't run the reset-challenge
    // against it. Instead these play the same phase sequence the real flow goes through:
    // .needsRecovery → (recover) .recovering → .needsReboot → (reconnectAndFinish) .connecting →
    // .recovering → .ready, with a fresh (unused) password in `newlyGeneratedPassword`.

    /// Demo only: pretend the ring rejected our password, so the recovery wizard can be tried.
    func simulateNeedsRecovery() {
        guard isDemo, phase == .ready else { return }
        demoRecoveryPending = true
        statusMessage = "DEMO: saved password rejected. Recovery required."
        SH2Log.log("DEMO: simulated password rejection — recovery required")
        phase = .needsRecovery
    }

    private func demoRecover() async {
        guard demoRecoveryPending, phase == .needsRecovery else { return }
        phase = .recovering
        statusMessage = "Un-pairing (reset-challenge)…"
        SH2Log.log("DEMO: reset-challenge (simulated)")
        try? await Task.sleep(for: .seconds(1.5))
        statusMessage = "Un-paired ✓ — the ring must reboot once to finish."
        phase = .needsReboot
    }

    private func demoFinishRecovery() async {
        guard demoRecoveryPending else { return }
        phase = .connecting
        statusMessage = "Connecting…"
        try? await Task.sleep(for: .seconds(1.2))
        phase = .recovering
        statusMessage = "Re-pairing…"
        try? await Task.sleep(for: .seconds(0.8))
        demoRecoveryPending = false
        newlyGeneratedPassword = Recovery.generateDevicePassword()
        SH2Log.log("DEMO: re-paired with a fresh (simulated) password")
        await finishReady()
    }

    /// Demo only: walk away and come back — if the simulated alarm is ON, someone moved the bike
    /// meanwhile; then read the recap and re-apply the settings, as a real reconnect does.
    func simulateAlarm() async {
        guard let mock = demoTransport as? MockTransport else { return }
        mock.simulateAlarm()
        await syncAlarm()
        if lastAlarmReport?.triggerCount ?? 0 == 0 {
            statusMessage = "DEMO: turn the alarm on first."
        }
    }

    // Sound + touch (M2)
    func playSound() async        { await run(Commands.soundPlay(), "soundPlay") }
    func stopSound() async        { await run(Commands.soundStop(), "soundStop") }
    func setTouchSounds(on: Bool) async { await run(Commands.soundTouch(on: on), "touchSounds") }
    func runTouchOnboarding() async { await run(Commands.touchOnboarding(), "touchOnboarding") }

    // Navigation — driven by GuidanceController (`NavDirector`, reimplementation of the official app).

    /// A batch of commands waiting for the ring, in the order they were queued.
    private struct NavBatch {
        let commands: [NavCommand]
        /// A per-fix batch (the guidance's, a card's answer): the next one supersedes it when the
        /// ring is slow to take them.
        let droppable: Bool
        var isCarouselAnswer: Bool { commands.count == 1 && commands[0].label == "carousel" }
        var hasDelay: Bool { commands.contains { $0.delay > 0 } }
        var labels: String { commands.map(\.label).joined(separator: ", ") }
    }
    private var navPending: [NavBatch] = []
    private var navWorker: Task<Void, Never>?
    /// Bumped by `cancelNav()`: a batch whose delay started under an older epoch is abandoned.
    private var navEpoch = 0
    /// Beyond this many waiting batches the oldest droppable ones go: with the ring slow to answer,
    /// the per-fix batches would otherwise pile up and the ring later drain positions long gone.
    private static let navPendingLimit = 4

    /// Send navigation commands strictly in order, one in flight at a time (the official SDK's FIFO
    /// queue), after any earlier batch; a command's `delay` waits before it. `droppable` marks a
    /// batch the next one makes stale (a fix's guidance, a card's answer).
    func sendNav(_ commands: [NavCommand], droppable: Bool = false) {
        guard !commands.isEmpty else { return }
        let batch = NavBatch(commands: commands, droppable: droppable)
        if batch.isCarouselAnswer, let i = navPending.firstIndex(where: { $0.isCarouselAnswer }) {
            navPending[i] = batch           // the ring asks every second: only the newest answer counts
        } else {
            navPending.append(batch)
        }
        // Never a batch with a timed command (the arrival's `navOff` 10 s later) nor one the caller
        // didn't mark: intros, stops, alerts and sounds always go out.
        while navPending.count > Self.navPendingLimit,
              let i = navPending.firstIndex(where: { $0.droppable && !$0.hasDelay }) {
            let dropped = navPending.remove(at: i)
            SH2Log.log("nav queue: dropped a stale batch (\(dropped.labels))")
        }
        if navWorker == nil {
            navWorker = Task { @MainActor [weak self] in await self?.drainNav() }
        }
    }

    private func drainNav() async {
        while !navPending.isEmpty {
            let batch = navPending.removeFirst()
            let epoch = navEpoch
            for cmd in batch.commands {
                if cmd.delay > 0 {
                    try? await Task.sleep(for: .seconds(cmd.delay))
                    if epoch != navEpoch { break }      // cancelled meanwhile: a new ride started
                }
                await run(cmd.data, cmd.label)
            }
        }
        navWorker = nil
    }

    /// Drop the navigation commands not sent yet, delays included. A new ride calls it so that its
    /// intro doesn't queue behind the previous ride's arrival sequence (a `navOff` 10 s later).
    func cancelNav() {
        navPending.removeAll()
        navEpoch &+= 1
    }

    // Device settings (M4)
    func refreshDeviceState() async {
        guard let r = await transceiveRetrying(Commands.getState(), "getState") else { return }
        let hex = r.dropFirst().map { String(format: "%02x", $0) }.joined(separator: " ")
        deviceStateHex = hex.isEmpty ? "(empty)" : hex
        guard let state = DeviceState(reply: r) else { return }
        if let on = state.lightOn { lightOn = on }
        updateBattery(level: state.stateOfCharge, charging: state.charging,
                      plugged: state.plugged ?? state.charging, temperature: state.temperature)
    }
    func calibrateCompass() async { await run(Commands.compassCalibrate(), "compassCalibrate") }
    func syncTime() async {
        let secs = UInt64(max(0, Date().timeIntervalSince1970))
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        await run(Commands.localization(unixSeconds: secs, language: lang), "localization")
    }
    func shutdownDevice() async { await run(Commands.shutdown(), "shutdown") }
    /// The password this iPhone uses for the ring (for Settings › Advanced: show / copy).
    var savedPassword: String? { isDemo ? newlyGeneratedPassword : KeychainStore.load(deviceID: deviceID) }

    /// Use a password the user saved elsewhere (e.g. their password manager). Reconnects and
    /// authenticates with it alone; it's stored only if the ring accepts it. Otherwise reconnects
    /// with the stored passwords, so a typo doesn't leave us locked out.
    @discardableResult
    func useSavedPassword(_ password: String) async -> Bool {
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty, !isDemo else { return false }
        await restart(only: password)
        if phase == .ready { return true }
        await restart()
        statusMessage = "That password was rejected by the ring."
        return false
    }

    func forgetSavedPassword() {
        KeychainStore.delete(deviceID: deviceID)
        statusMessage = "Saved password removed — recover again to re-pair."
    }

    func refreshAlarmReport() async {
        if await fetchAlarmReport(recap: false) == nil { statusMessage = "alarm report unavailable" }
    }

    func refreshInfo() async {
        guard let session = readySession else { return }
        do {
            let r = [UInt8](try await session.transceive(Commands.getVersions()))
            if r.count >= 9, r[0] == ReturnCode.ok.rawValue {
                firmwareVersion = r[1...4].map { "\($0)" }.joined(separator: ".")
                bootloaderVersion = r[5...8].map { "\($0)" }.joined(separator: ".")
            }
        } catch { statusMessage = "getVersions failed: \(describe(error))" }

        do {
            let r = try await session.transceive(Commands.getSerial(0))
            let body = Data(r.dropFirst()) // drop return code
            let ascii = String(data: body, encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            let text = (ascii?.isEmpty == false)
                ? ascii!
                : body.map { String(format: "%02x", $0) }.joined()
            serial = text.isEmpty ? "—" : text
        } catch { statusMessage = "getSerial failed: \(describe(error))" }
    }

    // MARK: - Helpers

    private func describe(_ error: Error) -> String {
        if let e = error as? Session.SessionError { return "\(e)" }
        if let e = error as? Recovery.RecoveryError { return "\(e)" }
        if let e = error as? Crypto.CryptoError { return "\(e)" }
        return error.localizedDescription
    }
}
