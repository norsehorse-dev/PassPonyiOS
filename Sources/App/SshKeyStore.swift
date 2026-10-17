import Foundation
import Security

/// The app's SSH key and the SSH hosts it trusts (2.0 rc2).
///
/// One key per app. The private key lives in the Keychain, this device
/// only and readable only while the device is unlocked, and is read for
/// each network operation; nothing writes it to a file. The encrypted
/// `.passpony` backup carries a copy, so the Keychain item is never the
/// only way back to the key.
///
/// Known hosts are an OpenSSH known_hosts file in the app group container;
/// the core reads and edits it (`knownHostsAdd`, `knownHostsRemove`).
enum SshKeyStore {
    private static let service = "passpony.ssh-key"

    /// Goes on the public key line, so a host's key list shows where it came from.
    static let comment = "passpony-ios"

    private static var directory: URL {
        StorePaths.container.appendingPathComponent("ssh", isDirectory: true)
    }

    private static var knownHostsURL: URL {
        directory.appendingPathComponent("known_hosts")
    }

    // MARK: - Key

    static var hasKey: Bool { privateKeyData() != nil }

    /// The stored key with its public half and fingerprint, or nil.
    static func load() -> SshKey? {
        guard var data = privateKeyData() else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        return try? sshImportKey(data: data, passphrase: nil)
    }

    /// A new Ed25519 key, stored. Replaces nothing: delete first.
    @discardableResult
    static func generate() throws -> SshKey {
        let key = try sshGenerateKey(comment: comment)
        try save(key)
        return key
    }

    /// Import an OpenSSH private key file. Throws `.NeedsPassphrase` for a
    /// protected key without a passphrase and `.WrongPassphrase` for a bad
    /// one; nothing is written in either case.
    @discardableResult
    static func importKey(_ data: Data, passphrase: String?) throws -> SshKey {
        let key = try sshImportKey(data: data, passphrase: passphrase)
        try save(key)
        return key
    }

    /// Store `key` as this app's SSH key, replacing any current one.
    static func save(_ key: SshKey) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: Data(key.privateKey.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func privateKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: - Known hosts

    static var knownHosts: String {
        (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
    }

    static var trustedHosts: [KnownHost] { knownHostsList(text: knownHosts) }

    static func isPinned(_ host: String) -> Bool {
        trustedHosts.contains { $0.host == host }
    }

    /// Pin `key` for `host` after the user confirmed its fingerprint.
    static func trust(host: String, key: HostKey) throws {
        try writeKnownHosts(knownHostsAdd(text: knownHosts, host: host, key: key))
    }

    static func forget(host: String) throws {
        try writeKnownHosts(knownHostsRemove(text: knownHosts, host: host))
    }

    private static func writeKnownHosts(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: knownHostsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// What the git transport needs for SSH remotes; HTTPS ignores it.
    static func config() -> SshConfig {
        SshConfig(privateKey: load()?.privateKey, knownHosts: knownHosts)
    }
}
