import Foundation
import CryptoKit
import CommonCrypto

/// Link-layer crypto for the SmartHalo 2: ECDH (NIST P-256) key agreement +
/// AES-128-CBC/PKCS7 message encryption + the reset-challenge hash.
///
/// 1:1 port of `sh2-core/src/crypto.mjs`. We act as the "central" (same role as the
/// official app). See `docs/protocol/ble-link.md` §4–5.
///
/// Apple-API mapping of the Node `crypto` primitives used by the reference:
/// - `createECDH('prime256v1')`            → `P256.KeyAgreement` (CryptoKit)
/// - `ecdh.computeSecret(peer)` (raw X)    → `SharedSecret` raw bytes (its 32-byte X coord)
/// - `createCipheriv('aes-128-cbc', …)`    → `CCCrypt` (CommonCrypto; CryptoKit has no AES-CBC)
/// - `createHash('sha256')`                → `SHA256` (CryptoKit)
public enum Crypto {

    public enum CryptoError: Error, Sendable {
        case badPeripheralKeyLength(Int)
        case badSeedLength(Int)
        case badSecretLength(Int)
        case badSaltLength(Int)
        case ccCryptFailed(Int32)
    }

    /// Derived link-session key material. `key` = secret[0..16], `iv` = secret[16..32].
    public struct LinkKeys: Sendable, Equatable {
        public let key: Data    // 16 bytes — AES-128 key
        public let iv: Data     // 16 bytes — CBC IV (its first 4 bytes are the device seed)
        public let secret: Data // 32 bytes — full shared secret (X coord with seed patched in)

        public init(key: Data, iv: Data, secret: Data) {
            self.key = key
            self.iv = iv
            self.secret = secret
        }

        /// Rebuild the keys from a stored `secret` (32 bytes: key ‖ IV).
        public init?(secret: Data) {
            guard secret.count == 32 else { return nil }
            let s = Data(secret)   // indices from 0
            self.init(key: s.subdata(in: 0..<16), iv: s.subdata(in: 16..<32), secret: s)
        }
    }

    // MARK: - ECDH (P-256)

    /// Generate the central's ephemeral P-256 key pair.
    /// Port of `generateKeyPair()`.
    public static func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    /// The central's public key in protocol wire format: X‖Y big-endian, 64 bytes, no 0x04 prefix.
    /// Port of `publicKeyXY(ecdh)`.
    ///
    /// CryptoKit's `x963Representation` is `0x04 ‖ X(32) ‖ Y(32)` (65 bytes); we drop the prefix.
    public static func publicKeyXY(_ privateKey: P256.KeyAgreement.PrivateKey) -> Data {
        Data(privateKey.publicKey.x963Representation.dropFirst())
    }

    /// Derive the AES key + IV from the ECDH agreement.
    /// Port of `deriveSecret(ecdh, periphPubKeyXY, seed)`.
    ///
    /// Steps (must match the firmware / `CentralKeyEncryption.java` exactly):
    /// 1. Peer public key = `0x04 ‖ periphPubKeyXY` → `P256.KeyAgreement.PublicKey`.
    /// 2. Shared secret = the RAW 32-byte X coordinate of the agreement (NOT HKDF-derived).
    /// 3. Overwrite bytes [16..20) of that secret with the device's 4-byte `seed`.
    /// 4. key = secret[0..16], iv = secret[16..32].
    public static func deriveSecret(
        privateKey: P256.KeyAgreement.PrivateKey,
        periphPubKeyXY: Data,
        seed: Data
    ) throws -> LinkKeys {
        guard periphPubKeyXY.count == 64 else { throw CryptoError.badPeripheralKeyLength(periphPubKeyXY.count) }
        guard seed.count == 4 else { throw CryptoError.badSeedLength(seed.count) }

        let x963 = Data([0x04]) + periphPubKeyXY
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: x963)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)

        // SharedSecret is the 32-byte X coordinate (big-endian). We need it RAW — CryptoKit
        // would normally steer you to `hkdfDerivedSymmetricKey(...)`, but the SH2 firmware uses
        // the bare agreement, so we read the raw bytes via ContiguousBytes.
        var secret = shared.withUnsafeBytes { Data($0) }
        guard secret.count == 32 else { throw CryptoError.badSecretLength(secret.count) }

        // Patch seed over [16..20) — same as crypto.mjs `seed.copy(secret, 16, 0, 4)`.
        secret.replaceSubrange(16..<20, with: seed)

        let key = secret.subdata(in: 0..<16)
        let iv = secret.subdata(in: 16..<32)
        return LinkKeys(key: key, iv: iv, secret: secret)
    }

    // MARK: - AES-128-CBC (PKCS#7)

    /// Encrypt an application payload. Port of `encrypt(key, iv, plaintext)`.
    public static func encrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        try crypt(operation: CCOperation(kCCEncrypt), key: key, iv: iv, input: plaintext)
    }

    /// Decrypt + strip PKCS#7 padding. Port of `decrypt(key, iv, ciphertext)`.
    public static func decrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        try crypt(operation: CCOperation(kCCDecrypt), key: key, iv: iv, input: ciphertext)
    }

    /// One-shot AES via CommonCrypto. `CCCrypt`'s default mode is CBC (there is no ECB option
    /// flag passed), and `kCCOptionPKCS7Padding` gives PKCS#7 — matching Node's
    /// `aes-128-cbc` with `setAutoPadding(true)`.
    private static func crypt(operation: CCOperation, key: Data, iv: Data, input: Data) throws -> Data {
        let bufferSize = input.count + kCCBlockSizeAES128
        var output = Data(count: bufferSize)
        var numBytesOut = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),       // CBC is implicit (no ECB flag)
                            keyPtr.baseAddress, key.count,          // key + key length (16)
                            ivPtr.baseAddress,                      // 16-byte IV
                            inPtr.baseAddress, input.count,         // input
                            outPtr.baseAddress, bufferSize,         // output buffer
                            &numBytesOut                            // bytes written
                        )
                    }
                }
            }
        }

        // `CCCryptorStatus` is Int32 while `kCCSuccess` imports as Int — cast to compare.
        guard status == CCCryptorStatus(kCCSuccess) else { throw CryptoError.ccCryptFailed(status) }
        return Data(output.prefix(numBytesOut))
    }

    // MARK: - Reset-challenge

    /// Reset-password challenge = `SHA-256( seed(4) ‖ salt(16) )` (32 bytes).
    /// Port of `resetPasswordChallenge(seed, salt)`; matches `auth.c::auth_cmd_resetPassword`.
    public static func resetPasswordChallenge(seed: Data, salt: Data) throws -> Data {
        guard seed.count == 4 else { throw CryptoError.badSeedLength(seed.count) }
        guard salt.count == 16 else { throw CryptoError.badSaltLength(salt.count) }
        var hasher = SHA256()
        hasher.update(data: seed)
        hasher.update(data: salt)
        return Data(hasher.finalize())
    }
}
