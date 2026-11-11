import XCTest
@testable import SH2Protocol

/// Validates the demo-mode Session path: `authenticateForDemo()` short-circuits the handshake, and a
/// plaintext mock device drives the full Session/Frame command round-trip (same mechanism the app's
/// `MockTransport` uses).
final class DemoSessionTests: XCTestCase {

    /// Minimal fake device: accumulates the outgoing frame and replies in plaintext.
    final class TinyMock: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var acc = Data()
        private let stream: AsyncStream<SH2Notification>
        private let cont: AsyncStream<SH2Notification>.Continuation

        init() {
            var c: AsyncStream<SH2Notification>.Continuation!
            stream = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
        }

        func enableNotifications() async throws {}
        func notificationStream() -> AsyncStream<SH2Notification> { stream }

        func write(uuid: String, data: Data) async throws {
            lock.lock(); defer { lock.unlock() }
            let u = uuid.uppercased()
            if Frame.UUIDs.payload.contains(u) {
                acc.append(data)
            } else if u == Frame.UUIDs.ctrl {
                let len = Int([UInt8](data).first ?? 0)
                let req = [UInt8](acc.prefix(len)); acc = Data()
                // getVersions {0,0} → [OK, fw(4), bl(4)]; everything else → [OK].
                let reply: Data = (req.first == 0 && req.count > 1 && req[1] == 0)
                    ? Data([0, 1, 2, 3, 4, 5, 6, 7, 8])
                    : Data([ReturnCode.ok.rawValue])
                guard let enc = try? Frame.encodeMessage(reply, cipher: nil) else { return }
                for (i, chunk) in enc.chunks.enumerated() where i < Frame.UUIDs.payload.count {
                    cont.yield(SH2Notification(uuid: Frame.UUIDs.payload[i], data: chunk))
                }
                cont.yield(SH2Notification(uuid: Frame.UUIDs.ctrl, data: enc.ctrl))
            }
        }
    }

    /// Like `TinyMock`, but it records the requests it gets and holds the reply to the first one
    /// until `releaseHeldReply()`, so that first request keeps the session's slot as long as a test
    /// wants. Every reply is `[OK]`.
    final class HoldingMock: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var acc = Data()
        private var requests: [[UInt8]] = []
        private var holding = true
        private var held: [SH2Notification] = []
        private let stream: AsyncStream<SH2Notification>
        private let cont: AsyncStream<SH2Notification>.Continuation

        init() {
            var c: AsyncStream<SH2Notification>.Continuation!
            stream = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
        }

        func enableNotifications() async throws {}
        func notificationStream() -> AsyncStream<SH2Notification> { stream }

        func write(uuid: String, data: Data) async throws {
            lock.lock(); defer { lock.unlock() }
            let u = uuid.uppercased()
            if Frame.UUIDs.payload.contains(u) { acc.append(data); return }
            guard u == Frame.UUIDs.ctrl else { return }
            let len = Int([UInt8](data).first ?? 0)
            requests.append([UInt8](acc.prefix(len))); acc = Data()
            guard let enc = try? Frame.encodeMessage(Data([ReturnCode.ok.rawValue]), cipher: nil) else { return }
            var notes: [SH2Notification] = []
            for (i, chunk) in enc.chunks.enumerated() where i < Frame.UUIDs.payload.count {
                notes.append(SH2Notification(uuid: Frame.UUIDs.payload[i], data: chunk))
            }
            notes.append(SH2Notification(uuid: Frame.UUIDs.ctrl, data: enc.ctrl))
            if holding { holding = false; held = notes } else { notes.forEach { cont.yield($0) } }
        }

        /// The requests received so far, as their app-data bytes.
        var recorded: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return requests }

        func releaseHeldReply() {
            lock.lock(); let notes = held; held = []; lock.unlock()
            notes.forEach { cont.yield($0) }
        }
    }

    func testDemoAuthAndPlaintextRoundTrip() async throws {
        let session = Session(transport: TinyMock())
        try await session.open()
        await session.authenticateForDemo()

        let authed = await session.isAuthenticated
        XCTAssertTrue(authed, "demo auth should mark the session authenticated")

        let versions = try await session.transceive(Commands.getVersions(), crypted: false)
        XCTAssertEqual([UInt8](versions), [0, 1, 2, 3, 4, 5, 6, 7, 8])

        let light = try await session.transceive(Commands.frontLight(on: true), crypted: false)
        XCTAssertEqual([UInt8](light).first, ReturnCode.ok.rawValue)
    }

    /// Requests made while another is in flight wait their turn instead of failing: the light
    /// toggle, the guidance and the carousel's answer all get through, in order.
    func testConcurrentRequestsTakeTurns() async throws {
        let session = Session(transport: TinyMock())
        try await session.open()
        await session.authenticateForDemo()
        async let a = session.transceive(Commands.getVersions(), crypted: false)
        async let b = session.transceive(Commands.frontLight(on: true), crypted: false)
        async let c = session.transceive(Commands.getVersions(), crypted: false)
        let (ra, rb, rc) = try await (a, b, c)
        XCTAssertEqual([UInt8](ra), [0, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual([UInt8](rb), [ReturnCode.ok.rawValue])
        XCTAssertEqual([UInt8](rc), [0, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    /// The firmware reads the command byte even when it isn't there: `[4]` would run `{4,0}`
    /// (enter bootloader). Such a request never leaves the phone.
    func testARequestShorterThanTwoBytesIsRefused() async throws {
        let session = Session(transport: TinyMock())
        try await session.open()
        await session.authenticateForDemo()
        do {
            _ = try await session.transceive(Data([4]), crypted: false)
            XCTFail("a 1-byte request must be refused")
        } catch Session.SessionError.requestTooShort(let count) {
            XCTAssertEqual(count, 1)
        }
        // The session is still usable afterwards.
        let light = try await session.transceive(Commands.frontLight(on: true), crypted: false)
        XCTAssertEqual([UInt8](light).first, ReturnCode.ok.rawValue)
    }

    /// A request whose task is cancelled while it waits its turn is not sent when the turn comes:
    /// a screen that left, or a ride that ended, doesn't talk to the ring afterwards.
    func testACancelledRequestWaitingItsTurnIsNotSent() async throws {
        let mock = HoldingMock()
        let session = Session(transport: mock)
        try await session.open()
        await session.authenticateForDemo()

        let first = Task { try await session.transceive(Commands.getVersions(), crypted: false) }
        // Once the first request is on the wire it holds the slot: its reply is held back.
        for _ in 0..<200 where mock.recorded.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(mock.recorded.count, 1, "the first request should be on the wire")

        let second = Task { try await session.transceive(Commands.frontLight(on: true), crypted: false) }
        try await Task.sleep(for: .milliseconds(100))       // queued behind the first
        second.cancel()
        mock.releaseHeldReply()

        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("a request cancelled while waiting must not be sent")
        } catch is CancellationError {}
        XCTAssertEqual(mock.recorded, [[0, 0]], "only getVersions reached the transport")

        // The slot was released on the way out: the session is still usable.
        let light = try await session.transceive(Commands.frontLight(on: true), crypted: false)
        XCTAssertEqual([UInt8](light).first, ReturnCode.ok.rawValue)
    }
}
