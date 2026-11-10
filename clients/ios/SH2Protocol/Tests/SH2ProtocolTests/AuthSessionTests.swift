import XCTest
import CryptoKit
@testable import SH2Protocol

/// The handshake against a model of the firmware's auth service (`auth.c` + `bslink.c`), with real
/// ECDH and AES: a rejected password leaves the link usable for another, and an un-paired ring
/// takes the empty password and then keeps the one it's given.
final class AuthSessionTests: XCTestCase {

    /// The nRF side of service 0 as `auth.c` does it: getPeriphPubKey, setCentralPubKey,
    /// authenticate, setPassword. Once the shared secret is set, replies are encrypted
    /// (`bslink_write`), and a failed authenticate changes nothing. One instance is one BLE link:
    /// each `Session` opened on it (one app process) gets the notifications from then on.
    final class FirmwareAuthMock: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var acc = Data()
        private var cont: AsyncStream<SH2Notification>.Continuation?
        private let deviceKey = P256.KeyAgreement.PrivateKey()
        private let seed = Data([0xA1, 0xB2, 0xC3, 0xD4])
        private var keys: Crypto.LinkKeys?
        private var authed = false
        private var stored: Data

        /// The password the ring holds now.
        var password: Data { lock.lock(); defer { lock.unlock() }; return stored }

        init(password: Data) {
            stored = password
        }

        func enableNotifications() async throws {}

        func notificationStream() -> AsyncStream<SH2Notification> {
            var c: AsyncStream<SH2Notification>.Continuation!
            let stream = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            lock.lock(); defer { lock.unlock() }
            cont?.finish()
            cont = c
            return stream
        }

        func writeNoResponse(uuid: String, data: Data) async throws {
            lock.lock(); defer { lock.unlock() }
            let u = uuid.uppercased()
            if Frame.UUIDs.payload.contains(u) { acc.append(data); return }
            guard u == Frame.UUIDs.ctrl else { return }
            let ctrl = [UInt8](data)
            let body = Data(acc.prefix(Int(ctrl[0])))
            acc = Data()
            var request = body
            if ctrl.count > 1, ctrl[1] != 0 {
                guard let keys else { throw Frame.FrameError.encryptedButNoKey }
                request = try Crypto.decrypt(key: keys.key, iv: keys.iv, ciphertext: body)
            }
            let response = try handle([UInt8](request))
            reply(response)
        }

        private func handle(_ req: [UInt8]) throws -> Data {
            guard req.count >= 2, req[0] == 0 else { return Data([ReturnCode.unimplemented.rawValue]) }
            let args = Data(req.dropFirst(2))
            switch req[1] {
            case 1:   // getPeriphPubKey → [OK, pub(64), seed(4)]
                return Data([ReturnCode.ok.rawValue]) + Crypto.publicKeyXY(deviceKey) + seed
            case 2:   // setCentralPubKey → the shared secret, seed over bytes 16..<20
                let peer = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + args)
                var secret = try deviceKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
                secret.replaceSubrange(16..<20, with: seed)
                keys = Crypto.LinkKeys(key: secret.subdata(in: 0..<16), iv: secret.subdata(in: 16..<32),
                                       secret: secret)
                return Data([ReturnCode.ok.rawValue])
            case 3:   // authenticate: exact match, no side effect on a mismatch
                guard args == stored else { return Data([ReturnCode.fail.rawValue]) }
                authed = true
                return Data([ReturnCode.ok.rawValue])
            case 4:   // setPassword: needs an authenticated link
                guard authed else { return Data([ReturnCode.denied.rawValue]) }
                stored = args
                return Data([ReturnCode.ok.rawValue])
            default:
                return Data([ReturnCode.unimplemented.rawValue])
            }
        }

        private func reply(_ data: Data) {
            guard let cont, let enc = try? Frame.encodeMessage(data, cipher: keys) else { return }
            for (i, chunk) in enc.chunks.enumerated() {
                cont.yield(SH2Notification(uuid: Frame.UUIDs.payload[i], data: chunk))
            }
            cont.yield(SH2Notification(uuid: Frame.UUIDs.ctrl, data: enc.ctrl))
        }
    }

    private let mine = String(repeating: "A", count: 32)
    private let other = String(repeating: "B", count: 32)

    func testARejectedPasswordLeavesTheLinkForAnother() async throws {
        let session = Session(transport: FirmwareAuthMock(password: Data(mine.utf8)))
        try await session.open()
        try await session.establishLink()

        let wrong = try await session.authenticate(password: Data(other.utf8))
        XCTAssertFalse(wrong)
        let afterWrong = await session.isAuthenticated
        XCTAssertFalse(afterWrong)

        let right = try await session.authenticate(password: Data(mine.utf8))
        XCTAssertTrue(right)
        let afterRight = await session.isAuthenticated
        XCTAssertTrue(afterRight)
    }

    func testHandshakeThrowsOnARejectedPassword() async throws {
        let session = Session(transport: FirmwareAuthMock(password: Data(mine.utf8)))
        try await session.open()
        do {
            try await session.handshake(password: other)
            XCTFail("a wrong password must not authenticate")
        } catch Session.SessionError.commandFailed(let step, let code) {
            XCTAssertEqual(step, "authenticate")
            XCTAssertEqual(code, ReturnCode.fail.rawValue)
        }
    }

    /// A killed app's link handed to the relaunched one: the ring saw no new connection and still
    /// encrypts with the first session's keys.
    func testARelaunchedAppTakesOverTheLinkWithTheLastKeys() async throws {
        let ring = FirmwareAuthMock(password: Data(mine.utf8))
        let first = Session(transport: ring)
        try await first.open()
        let keys = try await first.establishLink()
        let firstIn = try await first.authenticate(password: Data(mine.utf8))
        XCTAssertTrue(firstIn)
        await first.close()

        // Without the keys, the reply to getPeriphPubKey can't be read.
        let stranger = Session(transport: ring)
        try await stranger.open()
        do {
            try await stranger.establishLink()
            XCTFail("the reply is encrypted with the first session's keys")
        } catch Frame.FrameError.encryptedButNoKey {}
        await stranger.close()

        // With them, the link is re-keyed and the password goes through.
        let relaunched = Session(transport: ring)
        try await relaunched.open()
        let newKeys = try await relaunched.establishLink(resuming: keys)
        XCTAssertNotEqual(newKeys, keys)
        let relaunchedIn = try await relaunched.authenticate(password: Data(mine.utf8))
        XCTAssertTrue(relaunchedIn)
    }

    func testStoredLinkKeysRoundTrip() throws {
        let secret = Data((0..<32).map { UInt8($0) })
        let keys = try XCTUnwrap(Crypto.LinkKeys(secret: secret))
        XCTAssertEqual(keys.key, secret.prefix(16))
        XCTAssertEqual(keys.iv, Data(secret.suffix(16)))
        XCTAssertNil(Crypto.LinkKeys(secret: Data(count: 31)))
    }

    func testAnUnpairedRingTakesTheEmptyPasswordThenKeepsTheOneItIsGiven() async throws {
        let ring = FirmwareAuthMock(password: Data())
        let session = Session(transport: ring)
        try await session.open()
        try await session.establishLink()

        let saved = try await session.authenticate(password: Data(mine.utf8))
        XCTAssertFalse(saved)
        let empty = try await session.authenticate(password: Data())
        XCTAssertTrue(empty)

        try await Recovery.setPassword(session: session, mine)
        XCTAssertEqual(ring.password, Data(mine.utf8))
    }
}
