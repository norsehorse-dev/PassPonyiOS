// Real passage-store crypto: AgePonyCore (pure-Swift age v1) behind the
// generated CryptoBackend protocol.
//
// Identities live in an age identities file in the app-group container,
// mirroring ~/.passage/identities: one AGE-SECRET-KEY-1... per line, blank
// lines and # comments ignored. Passphrase-protected identity files and
// plugin identities (age-plugin-yubikey) are later work — see the plan §7.

import AgePonyCore
import Foundation

final class AgePonyEngine: CryptoBackend {
    private let identities: [X25519Identity]

    init(identities: [X25519Identity]) {
        self.identities = identities
    }

    convenience init(identitiesFile url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let ids = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { try? X25519Identity(ageIdentity: $0) }
        self.init(identities: ids)
    }

    /// pass-core's resolution hands us "age1..." recipient strings, or an
    /// empty list for the identities-fallback branch (no .age-recipients
    /// anywhere up the tree) — in that case we encrypt to our own public
    /// keys, exactly as `age -e -i identities` does.
    func encrypt(plaintext: Data, recipients: [String]) throws -> Data {
        guard !identities.isEmpty || !recipients.isEmpty else {
            throw CryptoError.NoUsableKey
        }
        do {
            let targets: [AgeRecipient] = recipients.isEmpty
                ? try identities.map { try X25519Recipient(publicKey: $0.publicKey) }
                : try recipients.map { try X25519Recipient(ageRecipient: $0) }
            return try Age.encrypt(plaintext: plaintext, to: targets)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.EncryptionFailed
        }
    }

    func decrypt(ciphertext: Data) throws -> Data {
        guard !identities.isEmpty else { throw CryptoError.NoUsableKey }
        do {
            return try Age.decrypt(ciphertext: ciphertext, identities: identities)
        } catch {
            throw CryptoError.DecryptionFailed
        }
    }
}

enum AgeIdentityStore {
    static var identitiesFile: URL {
        StorePaths.container.appendingPathComponent("identities")
    }

    /// Load the engine from the identities file; on first run, generate one
    /// identity and persist it (file protection on, 0600) so the store works
    /// out of the box. Import/export and passphrase protection are upcoming
    /// P3 work — the exportable-key rule from the plan applies here too.
    static func loadOrCreateEngine() throws -> AgePonyEngine {
        let url = identitiesFile
        if !FileManager.default.fileExists(atPath: url.path) {
            let identity = X25519Identity.generate()
            let text = """
            # created by PassPony
            # public key: \(identity.ageRecipient)
            \(identity.ageIdentityString)

            """
            try Data(text.utf8).write(to: url, options: [.completeFileProtection])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
        return try AgePonyEngine(identitiesFile: url)
    }
}
