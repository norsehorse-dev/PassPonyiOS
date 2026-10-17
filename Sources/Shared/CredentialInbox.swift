// CredentialInbox.swift
// Shared, byte-for-byte, between Umbra and PassPony.
//
// A minimal, dependency-free handoff queue for logins Umbra captures and
// PassPony encrypts into the store. Umbra enqueues; PassPony drains, imports,
// and removes.
//
// Storage is a shared KEYCHAIN access group (primary) with an app-group file
// queue as a fallback. Keychain items are encrypted at rest by iOS and never
// leave the device (ThisDeviceOnly, WhenUnlocked); the file fallback keeps the
// feature working if the keychain-access-group entitlement is not yet
// provisioned. Draining reads and clears both.
//
// NOTE: keep this file identical in both apps. It has no dependency on either
// app's types.

import Foundation
import Security

struct PendingCredential: Codable {
    let id: String
    let host: String        // bare host, e.g. "github.com"
    let username: String
    let password: String
    let url: String
    let createdAt: Date

    init(host: String, username: String, password: String, url: String) {
        self.id = UUID().uuidString
        self.host = host
        self.username = username
        self.password = password
        self.url = url
        self.createdAt = Date()
    }
}

enum CredentialInbox {
    /// PassPony's app group (used by the file fallback). Umbra joins it.
    static let appGroupID = "group.dev.norsehorse.passpony"

    /// Shared keychain access group. Both apps declare
    /// `keychain-access-groups = $(AppIdentifierPrefix)dev.norsehorse.shared`.
    /// The value below must carry the team's App ID prefix — which equals the
    /// team ID (4AVJZV35G8) for this account. If your AppIdentifierPrefix ever
    /// differs from the team ID, update this string; the file fallback covers
    /// a mismatch in the meantime.
    static let keychainAccessGroup = "4AVJZV35G8.dev.norsehorse.shared"
    static let keychainService = "dev.norsehorse.passpony.inbox"

    // MARK: - Producer (Umbra)

    /// Store a captured login. Tries the keychain first, then the file queue.
    @discardableResult
    static func enqueue(_ credential: PendingCredential) -> Bool {
        if enqueueKeychain(credential) { return true }
        return enqueueFile(credential)
    }

    // MARK: - Consumer (PassPony)

    /// All pending credentials from both stores, de-duplicated by id, oldest
    /// first.
    static func pending() -> [PendingCredential] {
        var byID: [String: PendingCredential] = [:]
        for c in pendingKeychain() + pendingFile() {
            byID[c.id] = c
        }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Remove one imported item from wherever it lives.
    static func remove(id: String) {
        removeKeychain(id: id)
        removeFile(id: id)
    }

    static var isEmpty: Bool {
        pending().isEmpty
    }

    // MARK: - Keychain backing

    private static func keychainBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
        ]
    }

    private static func enqueueKeychain(_ credential: PendingCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        var query = keychainBaseQuery()
        query[kSecAttrAccount as String] = credential.id
        SecItemDelete(query as CFDictionary)  // idempotent
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func pendingKeychain() -> [PendingCredential] {
        var query = keychainBaseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(PendingCredential.self, from: data)
        }
    }

    private static func removeKeychain(id: String) {
        var query = keychainBaseQuery()
        query[kSecAttrAccount as String] = id
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - File backing (fallback)

    private static var directory: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let dir = container.appendingPathComponent("CredentialInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func enqueueFile(_ credential: PendingCredential) -> Bool {
        guard let directory else { return false }
        let file = directory.appendingPathComponent("\(credential.id).json")
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    private static func pendingFile() -> [PendingCredential] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(PendingCredential.self, from: data)
            }
    }

    private static func removeFile(id: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).json")
        )
    }
}

/// Whether PassPony is set up on this device. Determined WITHOUT any installed-
/// app detection API (no canOpenURL, no LSApplicationQueriesSchemes): Umbra
/// looks in the app group the two apps already share for the credential handoff
/// and checks for PassPony's store directory. Umbra learns nothing about any
/// other app, and nothing leaves the device.
enum PassPonyPresence {
    static var isAvailable: Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CredentialInbox.appGroupID
        ) else { return false }
        let fm = FileManager.default
        for name in ["store", "pass-store"] {
            var isDir: ObjCBool = false
            let path = container.appendingPathComponent(name, isDirectory: true).path
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return true
            }
        }
        return false
    }
}
