import Foundation
import Security

/// Per-device password storage in the iOS Keychain.
///
/// We generate and custodied our own 32-byte device password (see `Recovery`), exactly as the
/// official app did (`docs/protocol/pairing.md`). Losing it means running the reset-challenge
/// recovery again (which needs a cold reboot of the ring), so it can optionally be synced through
/// **iCloud Keychain** (`kSecAttrSynchronizable`) and can be shown/copied in Settings › Advanced.
///
/// Keyed by the CoreBluetooth peripheral identifier. That identifier is per-iPhone, so on another
/// iPhone a synced password arrives under a different account: `DeviceController` then tries the
/// other stored passwords (`fallbackPasswords(deviceID:)`) and re-saves the one that works.
///
/// Replacing a device's password keeps the old one under `<id>.previous`: a ring can come back
/// from a reboot with the password it had before (see `DeviceController.authenticate`).
enum KeychainStore {

    private static let service = "com.sh2.smarthalo2.devicePassword"

    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    private static func baseQuery(_ deviceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
    }

    /// The account that keeps the password a device's current one replaced.
    private static func previousAccount(_ deviceID: String) -> String { deviceID + ".previous" }

    /// Store (or replace) the password for a device. `synchronizable` puts it in iCloud Keychain.
    /// A different password already stored becomes the device's previous one.
    static func save(password: String, deviceID: String, synchronizable: Bool) throws {
        if let old = load(deviceID: deviceID), old != password {
            let previous = previousAccount(deviceID)
            try? add(Data(old.utf8), deviceID: previous, synchronizable: synchronizable)
            delete(deviceID: previous, synchronizable: !synchronizable)
        }
        try add(Data(password.utf8), deviceID: deviceID, synchronizable: synchronizable)
        // The new copy is in place; now drop the copy with the other sync flag, if any.
        delete(deviceID: deviceID, synchronizable: !synchronizable)
    }

    /// Load the password for a device (synced or local copy), or nil if none stored.
    static func load(deviceID: String) -> String? {
        var query = baseQuery(deviceID)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the stored passwords for a device (current and previous, synced or local copies).
    static func delete(deviceID: String) {
        for account in [deviceID, previousAccount(deviceID)] {
            var query = baseQuery(account)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Passwords to try when the ring rejects a device's current one, most likely first: the one
    /// it replaced, then those stored for other peripheral identifiers (e.g. synced from another
    /// iPhone). Unique, and without the current password.
    static func fallbackPasswords(deviceID: String) -> [String] {
        let previous = previousAccount(deviceID)
        let others = entries()
            .filter { $0.account != deviceID && $0.account != previous }
            .compactMap { load(account: $0.account, synchronizable: $0.synchronizable) }
        var seen = Set([load(deviceID: deviceID)].compactMap { $0 })
        return ([load(deviceID: previous)].compactMap { $0 } + others)
            .filter { seen.insert($0).inserted }
    }

    /// Move every stored password to (or out of) iCloud Keychain. Copy-then-delete, so a failure
    /// never loses the only copy.
    static func applySync(_ synchronizable: Bool) {
        for entry in entries() where entry.synchronizable != synchronizable {
            guard let password = load(account: entry.account, synchronizable: entry.synchronizable),
                  (try? add(Data(password.utf8), deviceID: entry.account, synchronizable: synchronizable)) != nil
            else { continue }
            delete(deviceID: entry.account, synchronizable: entry.synchronizable)
        }
    }

    // MARK: - Link keys

    private static let linkKeyService = "com.sh2.smarthalo2.linkKey"

    private static func linkKeyQuery(_ deviceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: linkKeyService,
            kSecAttrAccount as String: deviceID,
        ]
    }

    /// Keep the keys of the last handshake with a device (32 bytes: AES key ‖ IV), so a relaunched
    /// app can take over a link a killed one left up (`Session.establishLink(resuming:)`). This
    /// iPhone only, never synced: they're only good on a link this iPhone holds.
    static func saveLinkKeys(_ secret: Data, deviceID: String) {
        SecItemDelete(linkKeyQuery(deviceID) as CFDictionary)
        var attributes = linkKeyQuery(deviceID)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadLinkKeys(deviceID: String) -> Data? {
        var query = linkKeyQuery(deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: - Private

    private static func add(_ data: Data, deviceID: String, synchronizable: Bool) throws {
        delete(deviceID: deviceID, synchronizable: synchronizable)
        var attributes = baseQuery(deviceID)
        attributes[kSecValueData as String] = data
        // Synchronizable items can't be "ThisDeviceOnly"; AfterFirstUnlock works for both.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = synchronizable
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func delete(deviceID: String, synchronizable: Bool) {
        var query = baseQuery(deviceID)
        query[kSecAttrSynchronizable as String] = synchronizable
        SecItemDelete(query as CFDictionary)
    }

    private static func load(account: String, synchronizable: Bool) -> String? {
        var query = baseQuery(account)
        query[kSecAttrSynchronizable as String] = synchronizable
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every stored password item (attributes only), synced or local.
    private static func entries() -> [(account: String, synchronizable: Bool)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String else { return nil }
            let sync = (attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
            return (account, sync)
        }
    }
}
