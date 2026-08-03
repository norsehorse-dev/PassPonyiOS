// Time-boxed passphrase cache for protected OpenPGP keys — the PGPony
// 5-minute pattern. The passphrase lives in the app-group keychain
// (device-only, unlocked-state) so the autofill extension can decrypt within
// the same window; the expiry timestamp lives beside it in group defaults.
// Expiry shares UnlockGate's grace period so "unlocked" means one thing.

import Foundation
import Security

enum PassphraseCache {
    private static let service = "passpony.pgp-passphrase"
    private static let stampKey = "passpony.pgpPassphraseStamp"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: StorePaths.appGroupID) ?? .standard
    }

    static func save(_ passphrase: String) {
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: StorePaths.appGroupID,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(passphrase.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
        defaults.set(Date().timeIntervalSince1970, forKey: stampKey)
    }

    /// The cached passphrase, or nil once the grace window lapsed
    /// (the keychain item is cleared on expiry read).
    static func load() -> String? {
        let stamp = defaults.double(forKey: stampKey)
        guard stamp > 0,
              Date().timeIntervalSince1970 - stamp < UnlockGate.gracePeriod
        else {
            clear()
            return nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: StorePaths.appGroupID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: StorePaths.appGroupID,
        ]
        SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: stampKey)
    }
}
