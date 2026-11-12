import XCTest
@testable import SH2Protocol

/// Mirrors `sh2-core/test/frame.test.mjs`. Uses a fixed key/iv (no real ECDH needed here).
final class FrameTests: XCTestCase {

    private func fixedCipher() -> Crypto.LinkKeys {
        Crypto.LinkKeys(
            key: Data(repeating: 0xAB, count: 16),
            iv: Data(repeating: 0xCD, count: 16),
            secret: Data(count: 32))
    }

    func testEncodeDecodePlaintextRoundTrip() throws {
        let data = Data([0, 0]) // getVersions
        let enc = try Frame.encodeMessage(data, cipher: nil)
        XCTAssertEqual(enc.ctrl[1], 0, "not encrypted")
        XCTAssertEqual(enc.ctrl[0], 2)
        let accum = enc.chunks.reduce(Data(), +)
        XCTAssertEqual(try Frame.decodeReply(ctrl: enc.ctrl, payloadAccum: accum, cipher: nil), data)
    }

    func testChunksAt20ByteMTU() throws {
        let data = Data([1, 4]) + Data(repeating: 0xaa, count: 40) // 42 B
        let enc = try Frame.encodeMessage(data, cipher: nil)
        XCTAssertEqual(enc.chunks.count, 3)
        XCTAssertEqual(enc.chunks[0].count, Frame.mtu)
        XCTAssertEqual(enc.chunks[2].count, 2)
    }

    func testEncodeDecodeEncryptedRoundTrip() throws {
        let cipher = fixedCipher()
        let data = Data([0, 3, 1, 2, 3, 4, 5]) // authenticate
        let enc = try Frame.encodeMessage(data, cipher: cipher)
        XCTAssertEqual(enc.ctrl[1], 1, "encrypted")
        XCTAssertEqual(Int(enc.ctrl[0]) % 16, 0, "on-wire length is a multiple of 16")
        let accum = enc.chunks.reduce(Data(), +)
        XCTAssertEqual(try Frame.decodeReply(ctrl: enc.ctrl, payloadAccum: accum, cipher: cipher), data)
    }

    func testRejectsMessagesExceedingMaxAfterEncrypt() {
        let cipher = fixedCipher()
        // 80 B plaintext -> 96 B ciphertext -> exceeds 80 B max.
        XCTAssertThrowsError(try Frame.encodeMessage(Data(repeating: 1, count: Frame.maxMessage), cipher: cipher))
    }

    func testAnEmptyCtrlIsAnError() {
        XCTAssertThrowsError(try Frame.decodeReply(ctrl: Data(), payloadAccum: Data([0]), cipher: nil)) { error in
            guard case Frame.FrameError.malformedCtrl = error else { return XCTFail("\(error)") }
        }
    }

    func testACtrlLongerThanThePayloadIsAnError() {
        // CTRL says 69 bytes, only 3 arrived (a lost chunk): not a 3-byte reply.
        XCTAssertThrowsError(try Frame.decodeReply(ctrl: Data([69, 0]), payloadAccum: Data([0, 1, 2]), cipher: nil)) { error in
            guard case Frame.FrameError.truncatedReply(let expected, let got) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(expected, 69)
            XCTAssertEqual(got, 3)
        }
        // Extra bytes beyond `len` are ignored, as before.
        XCTAssertEqual(try Frame.decodeReply(ctrl: Data([2, 0]), payloadAccum: Data([0, 1, 2]), cipher: nil), Data([0, 1]))
    }

    func testUUIDsAreFull128Bit() {
        XCTAssertEqual(Frame.UUIDs.service, "92540000-D6ED-4617-A4B4-D749F57710CE")
        XCTAssertEqual(Frame.UUIDs.ctrl, "92540001-D6ED-4617-A4B4-D749F57710CE")
        XCTAssertEqual(Frame.UUIDs.payload.count, 4)
        XCTAssertEqual(Frame.UUIDs.allNotify.count, 10)
    }
}
