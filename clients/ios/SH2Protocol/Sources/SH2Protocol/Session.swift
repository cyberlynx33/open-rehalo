import Foundation

/// Logical session over a connectable BLE `Transport`. Orchestrates the ECDH→AES handshake and
/// `transceive` sequencing with bslink framing.
///
/// 1:1 port of `sh2-core/src/session.mjs`. The JS version relies on Node's single-threaded event
/// loop to keep notification callbacks ordered; here the same ordering is provided by a single
/// consumer loop over `Transport.notificationStream()`, and all mutable state is isolated to this
/// actor.
public actor Session {

    public enum SessionError: Error, Sendable {
        /// No longer thrown: requests wait their turn (see `transceive`). Kept for callers that
        /// still match it.
        case transceiveInProgress
        case commandFailed(step: String, code: UInt8?)
        case malformedReply(step: String)
        case closed
        /// The device never replied to a command within the timeout window.
        case timeout(step: String)
        /// The BLE link dropped while a command was in flight (common right after `resetPassword`,
        /// which un-pairs the device and may reset the connection).
        case disconnected
        /// A request shorter than `[service, command]`. The firmware reads the command byte anyway:
        /// a lone `[4]` reaches the STM32 as `{4,0}` and sends the nRF into its bootloader.
        case requestTooShort(Int)
    }

    /// Per round-trip reply timeout. A healthy device answers in well under a second; 8s leaves
    /// generous headroom while still breaking the previously-infinite wait.
    public static var replyTimeout: Duration = .seconds(8)

    private let transport: Transport
    private var cipher: Crypto.LinkKeys?

    // DOWN channel accumulation (request/reply).
    private var downAccum = Data()
    private var pending: CheckedContinuation<Data, Error>?
    /// Monotonic id of the in-flight request, so a late timeout only fires for its own request.
    private var pendingID: UInt64 = 0
    /// Human label of the in-flight request, for log lines.
    private var pendingLabel = ""
    /// The backstop of the in-flight request; cancelled as soon as it is answered.
    private var timeoutTask: Task<Void, Never>?
    /// The last reply's CTRL had the `crypted` flag set.
    private var lastReplyEncrypted = false

    // Requests take turns: one in flight at a time, in call order. The firmware handles one message
    // at a time and overwrites a reply in progress when another arrives (`bslink_write`), and the
    // app's callers (guidance on every fix, the carousel's answer every second, a tap on the light)
    // don't coordinate with each other.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Set once the session can't send any more; requests still queued fail with it.
    private var terminal: SessionError?

    // UP channel accumulation (unsolicited notifications).
    private var upAccum = Data()
    private var notificationHandler: (@Sendable (Data) -> Void)?

    private var consumer: Task<Void, Never>?

    /// True once `authenticate` has succeeded.
    public private(set) var isAuthenticated = false

    /// The keys of this link's last handshake (nil before one).
    public var linkKeys: Crypto.LinkKeys? { cipher }

    public init(transport: Transport) {
        self.transport = transport
    }

    /// Demo/testing ONLY: mark the session authenticated without the ECDH→AES handshake, so a mock
    /// transport that replies in plaintext can drive the full command path. The real cipher stays
    /// `nil`, so every `transceive` is sent in plaintext. Never used against a real device.
    public func authenticateForDemo() {
        isAuthenticated = true
    }

    /// Port of `Session.open()`: enable notifications and start consuming the notification stream.
    public func open() async throws {
        SH2Log.log("session: enabling notifications…")
        try await transport.enableNotifications()
        SH2Log.log("session: notifications enabled, consuming")
        let stream = transport.notificationStream()
        consumer = Task { [weak self] in
            // Single sequential consumer → notifications are handled strictly in arrival order.
            for await note in stream {
                await self?.handle(note)
            }
            // The stream only ends when the transport tears down — i.e. the link dropped. Break any
            // in-flight request instead of letting its `await` hang forever.
            await self?.onStreamEnded()
        }
    }

    private func onStreamEnded() {
        SH2Log.log("session: notification stream ended — BLE link closed")
        if terminal == nil { terminal = .disconnected }
        failPending(SessionError.disconnected)
    }

    /// Stop consuming and fail any in-flight request. Requests still waiting their turn fail too,
    /// in order, as each takes the slot and finds the session closed.
    public func close() {
        terminal = .closed
        consumer?.cancel()
        consumer = nil
        failPending(SessionError.closed)
    }

    // MARK: - One request at a time

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hand the slot to the next request in line, or free it.
    private func release() {
        if waiters.isEmpty { busy = false; return }
        waiters.removeFirst().resume()
    }

    /// Install a handler for unsolicited UP-channel notifications (e.g. alarm reports).
    public func setNotificationHandler(_ handler: (@Sendable (Data) -> Void)?) {
        notificationHandler = handler
    }

    // MARK: - Notification routing (runs serially, in order)

    private func handle(_ note: SH2Notification) {
        let u = note.uuid.uppercased()
        if Frame.UUIDs.payload.contains(u) {
            downAccum.append(note.data)
        } else if u == Frame.UUIDs.ctrl {
            onCtrl(note.data)
        } else if Frame.UUIDs.upPayload.contains(u) {
            upAccum.append(note.data)
        } else if u == Frame.UUIDs.upCtrl {
            onUpCtrl(note.data)
        }
        // Unknown UUIDs are ignored.
    }

    /// Port of `_onCtrl`: a DOWN CTRL completes the pending reply.
    private func onCtrl(_ ctrl: Data) {
        let encrypted = ctrl.count > 1 && [UInt8](ctrl)[1] != 0
        guard let p = pending else {
            // Nobody asked: a late reply, one to an earlier session on this link, or another app's.
            SH2Log.log("← reply with no request pending (\(encrypted ? "encrypted" : "plaintext")) — dropped")
            downAccum = Data()
            return
        }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lastReplyEncrypted = encrypted
        do {
            let reply = try Frame.decodeReply(ctrl: ctrl, payloadAccum: downAccum, cipher: cipher)
            downAccum = Data()
            SH2Log.log("← \(pendingLabel)  [\(SH2Log.hex(reply))]")
            p.resume(returning: reply)
        } catch {
            downAccum = Data()
            SH2Log.log("✗ \(pendingLabel): decode failed — \(error)")
            p.resume(throwing: error)
        }
    }

    /// Port of `_onUpCtrl`: a UP CTRL completes an unsolicited notification.
    private func onUpCtrl(_ ctrl: Data) {
        do {
            let data = try Frame.decodeReply(ctrl: ctrl, payloadAccum: upAccum, cipher: cipher)
            upAccum = Data()
            notificationHandler?(data)
        } catch {
            upAccum = Data()
        }
    }

    private func failPending(_ error: Error) {
        guard let p = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        downAccum = Data()
        SH2Log.log("✗ \(pendingLabel): \(error)")
        p.resume(throwing: error)
    }

    /// Fail the in-flight request if it is still the one identified by `id` (a late timeout must not
    /// clobber a subsequent request that already reused the `pending` slot).
    private func timeoutGuard(_ id: UInt64) async {
        try? await Task.sleep(for: Session.replyTimeout)
        guard pending != nil, pendingID == id else { return }
        SH2Log.log("✗ \(pendingLabel): no reply within \(Session.replyTimeout)")
        failPending(SessionError.timeout(step: pendingLabel))
    }

    // MARK: - transceive

    /// Send an application payload and await the reply. Port of `Session.transceive`.
    ///
    /// Requests queue up: a call made while another is in flight waits its turn (in call order)
    /// instead of failing, so a tap on the light during a ride no longer loses out to the guidance
    /// or the carousel answers.
    ///
    /// `crypted == nil` means "encrypt iff a cipher has been established" (matches the JS default).
    /// The REQUEST's encryption is controlled by this flag; the REPLY is decoded according to the
    /// `crypted` bit in its own CTRL using whatever cipher is currently set — which is why the
    /// handshake sets `cipher` *before* sending `setCentralPubKey` (the device encrypts that reply).
    @discardableResult
    public func transceive(_ appData: Data, crypted: Bool? = nil, label: String = "") async throws -> Data {
        guard appData.count >= 2 else { throw SessionError.requestTooShort(appData.count) }
        let tag = label.isEmpty ? "cmd \(SH2Log.hex(appData, max: 4))" : label

        await acquire()
        defer { release() }
        if let terminal { throw terminal }
        // Encoded once it is our turn: the cipher may have been set by a handshake step ahead of us.
        let useCipher = (crypted ?? (cipher != nil)) ? cipher : nil
        let encoded = try Frame.encodeMessage(appData, cipher: useCipher)
        SH2Log.log("→ \(tag)  [\(Self.loggable(appData))]")
        // Chunks of an earlier reply that never got its CTRL, or that arrived after its request had
        // timed out, must not be prepended to this reply.
        downAccum = Data()

        pendingID &+= 1
        let myID = pendingID
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            // `pending` is committed here (synchronously, on the actor) BEFORE any write is sent,
            // so the reply — which can only arrive after the device receives our CTRL — always
            // finds it. The device cannot reply before the final CTRL write completes.
            self.pending = cont
            self.pendingLabel = tag
            Task { await self.sendFrames(encoded) }
            // Backstop: if no reply (device ignored the command, or the link stalled without a
            // clean disconnect), fail after the timeout instead of hanging forever.
            self.timeoutTask = Task { await self.timeoutGuard(myID) }
        }
    }

    /// The request bytes for the log. `authenticate` {0,3} and `setPassword` {0,4} carry the device
    /// password, which must never reach the live log (it can be copied from the console): only their
    /// header and length are shown.
    static func loggable(_ appData: Data) -> String {
        let b = [UInt8](appData)
        if b.count >= 2, b[0] == 0, b[1] == 3 || b[1] == 4 {
            return "\(SH2Log.hex(Data(b.prefix(2)))) … (\(b.count)B, password redacted)"
        }
        return SH2Log.hex(appData)
    }

    private func sendFrames(_ encoded: Frame.Encoded) async {
        do {
            for (i, chunk) in encoded.chunks.enumerated() {
                try await transport.write(uuid: Frame.UUIDs.payload[i], data: chunk)
            }
            // The CTRL write triggers processing on the device (`bslink_recv`).
            try await transport.write(uuid: Frame.UUIDs.ctrl, data: encoded.ctrl)
        } catch {
            failPending(error)
        }
    }

    // MARK: - Handshake

    /// Full handshake. After success, frames are encrypted and the session is authenticated.
    /// Port of `Session.handshake(password)`. Pass empty `Data()` for an unpaired device.
    /// A rejected password throws `commandFailed(step: "authenticate", …)`.
    public func handshake(password: Data) async throws {
        try await establishLink()
        guard try await authenticate(password: password) else {
            throw SessionError.commandFailed(step: "authenticate", code: ReturnCode.fail.rawValue)
        }
    }

    /// Handshake steps 1–3: the ECDH key agreement. Afterwards every frame is encrypted and the
    /// ring takes `authenticate(password:)` attempts over this link. Returns the new link keys.
    ///
    /// `previous`: the keys of the last handshake with this ring. A relaunched app can be handed
    /// the physical link a killed one left behind; the ring then never saw a new connection, which
    /// is the only thing that turns its encryption off (`bslink_cryptData`), so it answers
    /// `getPeriphPubKey` encrypted with that handshake's keys. With them the reply still decodes
    /// and the link is re-keyed as usual. Only plaintext goes out until the new keys are set, so
    /// wrong keys just make this throw.
    @discardableResult
    public func establishLink(resuming previous: Crypto.LinkKeys? = nil) async throws -> Crypto.LinkKeys {
        SH2Log.log("handshake: start")
        let firstHandshake = cipher == nil
        if firstHandshake, let previous { cipher = previous }
        // 1. getPeriphPubKey (plaintext) -> [OK, pub(64), seed(4)]: in plaintext on a new link,
        //    encrypted on one left over from an earlier handshake.
        let r = try await transceive(Commands.getPeriphPubKey(), crypted: false, label: "getPeriphPubKey")
        if firstHandshake && lastReplyEncrypted {
            SH2Log.log("handshake: the ring answered on a link an earlier session left up — re-keying it")
        }
        let rb = [UInt8](r)
        guard rb.count >= 69 else { throw SessionError.malformedReply(step: "getPeriphPubKey") }
        guard rb[0] == ReturnCode.ok.rawValue else {
            throw SessionError.commandFailed(step: "getPeriphPubKey", code: rb.first)
        }
        let periphPub = Data(rb[1..<65])
        let seed = Data(rb[65..<69])

        // 2. derive secret, and set the cipher BEFORE setCentralPubKey (see transceive note).
        let kp = Crypto.generateKeyPair()
        let keys = try Crypto.deriveSecret(privateKey: kp, periphPubKeyXY: periphPub, seed: seed)
        cipher = keys
        SH2Log.log("handshake: ECDH secret derived (seed \(SH2Log.hex(seed)))")

        // 3. setCentralPubKey (plaintext request) -> [OK]
        let r2 = try await transceive(Commands.setCentralPubKey(Crypto.publicKeyXY(kp)), crypted: false, label: "setCentralPubKey")
        guard [UInt8](r2).first == ReturnCode.ok.rawValue else {
            throw SessionError.commandFailed(step: "setCentralPubKey", code: [UInt8](r2).first)
        }
        return keys
    }

    /// Handshake step 4: present a password over a link set up by `establishLink()`. True if the
    /// ring accepted it, false if it answered `RET_FAIL`: it holds another password. A mismatch has
    /// no lockout or kick-out in the firmware (`auth_authenticate`), so another password can be
    /// tried on the same link. Anything else (a timeout, a dropped link, a reply that doesn't
    /// decode) throws: it says nothing about the password.
    public func authenticate(password: Data) async throws -> Bool {
        let what = password.isEmpty ? "empty password" : "\(password.count)B password"
        let r = try await transceive(Commands.authenticate(password), crypted: true, label: "authenticate")
        let code = [UInt8](r).first
        if code == ReturnCode.ok.rawValue {
            isAuthenticated = true
            SH2Log.log("handshake: OK — authenticated with the \(what), link encrypted")
            return true
        }
        if code == ReturnCode.fail.rawValue {
            SH2Log.log("handshake: the ring rejected the \(what)")
            return false
        }
        throw SessionError.commandFailed(step: "authenticate", code: code)
    }

    /// Convenience overload: UTF-8 encode a string password (device passwords are 32 ASCII chars).
    public func handshake(password: String) async throws {
        try await handshake(password: Data(password.utf8))
    }
}
