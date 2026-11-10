import XCTest
@testable import SH2Protocol

/// The live log shows every request's bytes, except the device password: `authenticate` {0,3} and
/// `setPassword` {0,4} are logged with their header and length only.
final class SessionLogTests: XCTestCase {

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func append(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }

    func testThePasswordNeverReachesTheLog() async throws {
        let lines = Lines()
        SH2Log.setSink { line in lines.append(line) }
        defer { SH2Log.setSink(nil) }

        let session = Session(transport: DemoSessionTests.TinyMock())
        try await session.open()
        let password = Data("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345".utf8)
        _ = try await session.transceive(Commands.authenticate(password), crypted: false, label: "authenticate")
        _ = try await session.transceive(Commands.setPassword(password), crypted: false, label: "setPassword")
        // A command that isn't a secret is still logged in full.
        _ = try await session.transceive(Commands.frontLight(on: true), crypted: false, label: "frontLight")

        let all = lines.snapshot
        let passwordHex = SH2Log.hex(password, max: 64)
        let firstBytes = String(passwordHex.prefix(14))        // "41 42 43 44 45"
        XCTAssertFalse(all.isEmpty)
        for line in all {
            XCTAssertFalse(line.contains(firstBytes), "password bytes leaked: \(line)")
        }
        XCTAssertTrue(all.contains { $0.contains("→ authenticate") && $0.contains("redacted") })
        XCTAssertTrue(all.contains { $0.contains("→ setPassword") && $0.contains("redacted") })
        XCTAssertTrue(all.contains { $0.contains("→ frontLight") && $0.contains("01 04 01 00") })
    }

    func testLoggableRedactsOnlyThePasswordCommands() {
        XCTAssertEqual(Session.loggable(Data([0, 3, 0x41, 0x42])), "00 03 … (4B, password redacted)")
        XCTAssertEqual(Session.loggable(Data([0, 4])), "00 04 … (2B, password redacted)")
        XCTAssertEqual(Session.loggable(Data([0, 1])), "00 01")
        XCTAssertEqual(Session.loggable(Data([1, 4, 1, 0])), "01 04 01 00")
    }
}
