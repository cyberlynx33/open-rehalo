import Foundation

/// bslink link-layer framing + GATT UUIDs. 1:1 port of `sh2-core/src/frame.mjs`.
/// See `docs/protocol/ble-link.md` §2–3.
///
/// A logical message is ≤80 bytes, split across 4 PAYLOAD characteristics (20 B each) plus a
/// 2-byte CTRL `[len, crypted]`. The CTRL write/notify is what completes a message.
public enum Frame {

    public static let mtu = 20
    public static let payloadChars = 4
    public static let maxMessage = mtu * payloadChars // 80

    public enum FrameError: Error, Sendable {
        case messageTooLong(Int)
        case encryptedButNoKey
        /// A CTRL notification with no bytes: nothing says how long the reply is.
        case malformedCtrl
        /// The CTRL announced more bytes than the PAYLOAD chunks delivered (a chunk was lost).
        case truncatedReply(expected: Int, got: Int)
    }

    /// GATT UUIDs for the vendor service `9254xxxx-d6ed-4617-a4b4-d749f57710ce`.
    /// Stored uppercased to match `CBUUID.uuidString` on iOS.
    public enum UUIDs {
        private static func u(_ short: String) -> String { "9254\(short)-D6ED-4617-A4B4-D749F57710CE" }

        public static let service = u("0000")

        // DOWN channel: central → device requests, device → central replies.
        public static let ctrl = u("0001")
        public static let payload = [u("0010"), u("0011"), u("0012"), u("0013")]

        // UP channel: unsolicited device → central notifications (active only after auth).
        public static let upCtrl = u("0101")
        public static let upPayload = [u("0110"), u("0111"), u("0112"), u("0113")]

        /// Every characteristic whose CCCD must be enabled (all 10).
        public static let allNotify: [String] = [ctrl] + payload + [upCtrl] + upPayload
    }

    /// Encoded, ready-to-send message: PAYLOAD chunks (write to payload[0..n]) + the CTRL value.
    public struct Encoded: Sendable {
        public let chunks: [Data]
        public let ctrl: Data
    }

    /// Encode an application payload for transmission. Port of `encodeMessage(appData, cipher)`.
    ///
    /// If `cipher` is non-nil the body is AES-encrypted and `crypted` is set to 1, otherwise the
    /// plaintext is sent with `crypted = 0`. The length byte is the ON-WIRE length (post-padding).
    public static func encodeMessage(_ appData: Data, cipher: Crypto.LinkKeys?) throws -> Encoded {
        var body = appData
        var crypted: UInt8 = 0
        if let cipher {
            body = try Crypto.encrypt(key: cipher.key, iv: cipher.iv, plaintext: appData)
            crypted = 1
        }
        guard body.count <= maxMessage else { throw FrameError.messageTooLong(body.count) }

        var chunks: [Data] = []
        var i = 0
        while i < body.count {
            let end = min(i + mtu, body.count)
            chunks.append(body.subdata(in: i..<end))
            i += mtu
        }
        let ctrl = Data([UInt8(body.count & 0xff), crypted])
        return Encoded(chunks: chunks, ctrl: ctrl)
    }

    /// Decode a reply (or UP notification). Port of `decodeReply(ctrl, payloadAccum, cipher)`.
    ///
    /// `ctrl[0]` = on-wire length, `ctrl[1]` = crypted flag. If crypted, the accumulated payload
    /// (truncated to `len`) is decrypted with `cipher`.
    public static func decodeReply(ctrl: Data, payloadAccum: Data, cipher: Crypto.LinkKeys?) throws -> Data {
        let ctrlBytes = [UInt8](ctrl)
        guard let first = ctrlBytes.first else { throw FrameError.malformedCtrl }
        let len = Int(first)
        let crypted = ctrlBytes.count > 1 ? ctrlBytes[1] : 0
        guard payloadAccum.count >= len else {
            throw FrameError.truncatedReply(expected: len, got: payloadAccum.count)
        }
        let body = Data(payloadAccum.prefix(len))
        if crypted != 0 {
            guard let cipher else { throw FrameError.encryptedButNoKey }
            return try Crypto.decrypt(key: cipher.key, iv: cipher.iv, ciphertext: body)
        }
        return body
    }
}
