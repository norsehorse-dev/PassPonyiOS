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
    private var enclaveIdentity: TagIdentity?

    init(identities: [X25519Identity]) {
        self.identities = identities
    }

    init(enclaveIdentity: TagIdentity) {
        self.identities = []
        self.enclaveIdentity = enclaveIdentity
    }

    convenience init(identitiesFile url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(identitiesText: text)
    }

    convenience init(identitiesText text: String) {
        let ids = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { try? X25519Identity(ageIdentity: $0) }
        self.init(identities: ids)
    }

    /// True when these identities can decrypt what they encrypt to
    /// themselves: the import check that a file holds a usable identity.
    var canRoundTrip: Bool {
        let probe = Data("PassPony import probe".utf8)
        guard let ct = try? encrypt(plaintext: probe, recipients: []),
              let pt = try? decrypt(ciphertext: ct) else { return false }
        return pt == probe
    }

    /// pass-core's resolution hands us "age1..." recipient strings, or an
    /// empty list for the identities-fallback branch (no .age-recipients
    /// anywhere up the tree) — in that case we encrypt to our own public
    /// keys, exactly as `age -e -i identities` does.
    func encrypt(plaintext: Data, recipients: [String]) throws -> Data {
        guard !identities.isEmpty || enclaveIdentity != nil || !recipients.isEmpty else {
            throw CryptoError.NoUsableKey
        }
        do {
            let targets: [AgeRecipient]
            if recipients.isEmpty {
                if let enclaveIdentity {
                    targets = [enclaveIdentity.recipient]
                } else {
                    targets = try identities.map { try X25519Recipient(publicKey: $0.publicKey) }
                }
            } else {
                targets = try recipients.map { recipient -> AgeRecipient in
                    if TagRecipient.isTagRecipient(recipient) {
                        return try TagRecipient(ageRecipient: recipient)
                    }
                    return try X25519Recipient(ageRecipient: recipient)
                }
            }
            return try Age.encrypt(plaintext: plaintext, to: targets)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.EncryptionFailed
        }
    }

    func decrypt(ciphertext: Data) throws -> Data {
        guard !identities.isEmpty || enclaveIdentity != nil else { throw CryptoError.NoUsableKey }
        do {
            let keys: [AgeIdentity]
            if let enclaveIdentity {
                keys = [enclaveIdentity]
            } else {
                keys = identities.map { $0 as AgeIdentity }
            }
            return try Age.decrypt(ciphertext: ciphertext, identities: keys)
        } catch {
            throw CryptoError.DecryptionFailed
        }
    }
}

enum AgeIdentityStore {
    static var identitiesFile: URL {
        StorePaths.container.appendingPathComponent("identities")
    }

    /// Highest scrypt work factor accepted when unlocking a
    /// passphrase-protected identities file or a backup: 2^20 (1 GiB of
    /// scrypt memory), the same ceiling as the core's Android engine. age
    /// and gopass write 18; a file asking for more is refused rather than
    /// allowed to exhaust the phone.
    static let maxScryptWorkFactor = 20

    /// Load the engine from the identities file; on first run, generate one
    /// identity and persist it (file protection on, 0600) so the store works
    /// out of the box. Since 2.0 the user can back it up (Keys backup) and
    /// import more (identities are appended, never replaced).
    static func loadOrCreateEngine() throws -> AgePonyEngine {
        if EnclaveAgeIdentity.isEnabled {
            return try AgePonyEngine(enclaveIdentity: EnclaveAgeIdentity.load())
        }
        let url = identitiesFile
        if !FileManager.default.fileExists(atPath: url.path) {
            let identity = X25519Identity.generate()
            let text = """
            # created by PassPony
            # public key: \(identity.ageRecipient)
            \(identity.ageIdentityString)

            """
            try writeAtomically(text)
            KeyBackupState.markChanged()
        }
        return try AgePonyEngine(identitiesFile: url)
    }

    static var hasIdentities: Bool {
        FileManager.default.fileExists(atPath: identitiesFile.path)
    }

    /// The identities file's text, for a backup or a plain export.
    static func exportText() -> String? {
        try? String(contentsOf: identitiesFile, encoding: .utf8)
    }

    /// `# public key:` hints from the identities file, for display only.
    static func publicKeyHints() -> [String] {
        guard let text = exportText() else { return [] }
        return identitiesDescribe(text: text).compactMap(\.publicKeyHint)
    }

    static func identityCount() -> Int {
        guard let text = exportText() else { return 0 }
        return identitiesDescribe(text: text).count
    }

    struct ImportResult {
        let added: Int
        let alreadyPresent: Int
    }

    enum ImportError: Error {
        /// The text holds no identity that can decrypt what it encrypts.
        case noUsableIdentity
        /// A passphrase-protected file was picked without a passphrase.
        case passphraseRequired
        /// Wrong passphrase, or not a passphrase-protected file.
        case wrongPassphrase
        /// The file asks for more scrypt work than this device allows.
        case tooCostly
    }

    /// Same detection rule as Android, from the core: an age header,
    /// binary or armored, after any leading whitespace.
    static func isPassphraseProtected(_ data: Data) -> Bool {
        ageIsEncryptedIdentitiesFile(data: data)
    }

    /// Add the identities in `text` after checking at least one of them can
    /// decrypt what it encrypts (a self-encrypt probe). Appends through the
    /// core's `identitiesMerge`: identities already here stay, in place, so
    /// nothing encrypted to them becomes unreadable; duplicates are skipped.
    @discardableResult
    static func importIdentities(_ text: String) throws -> ImportResult {
        let probe = AgePonyEngine(identitiesText: text)
        guard probe.canRoundTrip else { throw ImportError.noUsableIdentity }
        let existing = exportText() ?? ""
        let merged = identitiesMerge(existing: existing, imported: text)
        if merged.added > 0 {
            try writeAtomically(merged.text)
            KeyBackupState.markChanged()
        }
        return ImportResult(added: Int(merged.added), alreadyPresent: Int(merged.alreadyPresent))
    }

    /// Import an identities file as picked: plaintext as is, or decrypted
    /// in memory with `passphrase` first when it is `age -p` encrypted
    /// (binary or armored, what gopass's age backend writes).
    @discardableResult
    static func importIdentitiesFile(_ data: Data, passphrase: String?) throws -> ImportResult {
        guard isPassphraseProtected(data) else {
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.noUsableIdentity }
            return try importIdentities(text)
        }
        guard let passphrase else { throw ImportError.passphraseRequired }
        var plain = try decryptWithPassphrase(data, passphrase: passphrase)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard let text = String(data: plain, encoding: .utf8) else { throw ImportError.noUsableIdentity }
        return try importIdentities(text)
    }

    /// Decrypt a passphrase-protected age file, binary or armored, with the
    /// work-factor ceiling above. Shared by identities import and backups.
    static func decryptWithPassphrase(_ data: Data, passphrase: String) throws -> Data {
        var binary = data
        if let text = String(data: data, encoding: .utf8), AgeArmor.looksArmored(text) {
            guard let decoded = try? AgeArmor.decode(text) else { throw ImportError.wrongPassphrase }
            binary = decoded
        } else if let start = data.firstIndex(where: { !(" \t\r\n".utf8.contains($0)) }), start > data.startIndex {
            binary = data.subdata(in: start..<data.endIndex)
        }
        do {
            return try Age.decrypt(
                ciphertext: binary,
                identities: [ScryptIdentity(passphrase: passphrase, maxWorkFactor: maxScryptWorkFactor)]
            )
        } catch ScryptStanzaError.invalidWorkFactor {
            throw ImportError.tooCostly
        } catch {
            throw ImportError.wrongPassphrase
        }
    }

    /// Write through a temp file and replace, so a crash leaves the old
    /// file or the new one, never half of one.
    private static func writeAtomically(_ text: String) throws {
        let body = text.hasSuffix("\n") ? text : text + "\n"
        try Data(body.utf8).write(to: identitiesFile, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: identitiesFile.path
        )
    }
}
