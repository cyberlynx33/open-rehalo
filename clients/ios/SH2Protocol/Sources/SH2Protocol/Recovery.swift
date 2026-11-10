import Foundation
import Security

/// Recovery of an owned device whose pairing password is unknown (the official app that set it
/// is gone). 1:1 port of `sh2-core/src/recovery.mjs`. See `docs/protocol/pairing.md`.
///
/// This is the legitimate way to re-take ownership of *your own* SmartHalo 2: the firmware
/// registers `getSeed`/`resetPassword` with permission 0 (always accessible, no auth needed).
public enum Recovery {

    public enum RecoveryError: Error, Sendable {
        case commandFailed(step: String, code: UInt8?)
        case malformedReply(step: String)
        /// `resetPassword` returned FAIL: the salt/algorithm of this unit differs from the public
        /// firmware. Stop here — do not retry blindly.
        case resetRejected(code: UInt8?)
    }

    /// Generate a 32-byte ASCII device password (same alphabet the app used).
    /// Port of `generateDevicePassword()`.
    public static func generateDevicePassword() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback to the system RNG; both are cryptographically secure on Apple platforms.
            var rng = SystemRandomNumberGenerator()
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        var s = ""
        for b in bytes { s.append(alphabet[Int(b) % alphabet.count]) }
        return s
    }

    /// Un-pair via the reset-challenge route (does NOT require the current password).
    /// `getSeed` (plaintext) → `resetPassword(SHA256(seed‖salt))` (plaintext). Port of `resetPairing`.
    ///
    /// NOTE: this clears the BLE password only, not the tap code (see `docs/protocol/pairing.md`).
    public static func resetPairing(session: Session, salt: Data = FirmwareConstants.authSalt) async throws {
        SH2Log.log("recovery: step 1/3 getSeed (plaintext, no auth)")
        let r1 = try await session.transceive(Commands.getSeed(), crypted: false, label: "getSeed")
        let b1 = [UInt8](r1)
        guard b1.count >= 5 else { throw RecoveryError.malformedReply(step: "getSeed") }
        guard b1[0] == ReturnCode.ok.rawValue else {
            throw RecoveryError.commandFailed(step: "getSeed", code: b1.first)
        }
        // The seed is re-randomized on each getSeed — must use this live value for the challenge.
        let seed = Data(b1[1..<5])
        let challenge = try Crypto.resetPasswordChallenge(seed: seed, salt: salt)
        SH2Log.log("recovery: step 2/3 resetPassword = SHA256(seed \(SH2Log.hex(seed)) ‖ salt)")

        let r2 = try await session.transceive(Commands.resetPassword(challenge), crypted: false, label: "resetPassword")
        guard [UInt8](r2).first == ReturnCode.ok.rawValue else {
            throw RecoveryError.resetRejected(code: [UInt8](r2).first)
        }
        SH2Log.log("recovery: resetPassword OK — device un-paired")
    }

    /// Re-pair: handshake with the empty password (device is now un-paired) and set a new one.
    /// Port of `repair`. Returns the new password — it is the only copy, persist it.
    @discardableResult
    public static func repair(session: Session, newPassword: String = generateDevicePassword()) async throws -> String {
        SH2Log.log("recovery: step 3/3 re-pair — handshake with empty password")
        try await session.handshake(password: "")   // un-paired device → empty auth OK
        try await setPassword(session: session, newPassword)
        SH2Log.log("recovery: DONE — new password set and owned")
        return newPassword
    }

    /// Store `password` on the ring (`setPassword`, encrypted). Needs an authenticated session; on
    /// an un-paired ring the empty password authenticates. The firmware takes 32 bytes.
    public static func setPassword(session: Session, _ password: String) async throws {
        SH2Log.log("recovery: setPassword (32-char password)")
        let r = try await session.transceive(Commands.setPassword(Data(password.utf8)), crypted: true, label: "setPassword")
        guard [UInt8](r).first == ReturnCode.ok.rawValue else {
            throw RecoveryError.commandFailed(step: "setPassword", code: [UInt8](r).first)
        }
    }

    /// Full recovery: reset-challenge + re-pair with a fresh password. Port of `recoverAccess`.
    /// After this you control the device over BLE (incl. the alarm); the old tap code is irrelevant.
    @discardableResult
    public static func recoverAccess(
        session: Session,
        salt: Data = FirmwareConstants.authSalt,
        newPassword: String? = nil
    ) async throws -> String {
        try await resetPairing(session: session, salt: salt)
        return try await repair(session: session, newPassword: newPassword ?? generateDevicePassword())
    }
}
