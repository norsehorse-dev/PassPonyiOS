// Classic-pass (OpenPGP) crypto over NorseHorsePGPCore — the shared,
// auditable core. Covers Cv25519 v4 and X25519/Ed25519 v6 keys in software.
//
// 2.1: everything NorseHorsePGPCore can't read (RSA and NIST-curve keys,
// GnuPG's AEAD/OCB packets, secret-subkeys-only exports) goes to the Rust
// engine in PassPonyCore (`PgpEngine`, rpgp, the pgp-engine feature), the
// same backend PassPony Desktop uses for pass stores. The Swift path stays
// first for the keys it handles; rpgp is the fallback, never a replacement.
//
// Keys live as files (armored or binary) in an app-group `pgp-keys/`
// directory. v0 recipient resolution matches `.gpg-id` strings against key
// fingerprints and 16-hex key IDs; user-ID/email matching lands when the
// core promotes user-ID parsing.

import Foundation
import NorseHorsePGPCore

final class PGPonyEngine: CryptoBackend {
    private struct KeyEntry {
        let raw: Data // binary (dearmored) key blob
        let infos: [ParsedPublicKeyInfo]
    }

    private let decryptionKeys: [Cv25519DecryptionKey]
    private let entries: [KeyEntry]
    /// Every key file, for the Rust fallback engine. Built on first use
    /// only: a Curve25519-only user never pays for loading (and unlocking)
    /// their keys a second time unless an entry actually needs rpgp.
    private let rpgp: RpgpFallback

    /// Load every key file in `keyDirectory`. Protected keys that can't be
    /// unlocked (no passphrase cached, or a wrong one) don't abort the load —
    /// they're recorded in `PGPKeyStore.lockedKeyFiles` and skipped for
    /// decryption, so unprotected keys keep working and Settings can offer
    /// the unlock prompt.
    init(keyDirectory: URL, passphrase: String? = nil) throws {
        var decryption: [Cv25519DecryptionKey] = []
        var loaded: [KeyEntry] = []
        var locked: [String] = []
        var blobs: [Data] = []
        // Files the Swift path couldn't use, by blob index: their lock
        // state comes from the Rust engine.
        var rustOnly: [(index: Int, name: String)] = []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: keyDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in files where !url.hasDirectoryPath {
            guard let rawFile = try? Data(contentsOf: url) else { continue }
            blobs.append(rawFile)
            let binary: Data
            if let text = String(data: rawFile, encoding: .utf8),
               text.contains("-----BEGIN") {
                guard let dearmored = try? OpenPGPPacketParser.dearmor(text) else {
                    rustOnly.append((blobs.count - 1, url.lastPathComponent))
                    continue
                }
                binary = dearmored
            } else {
                binary = rawFile
            }
            guard let material = PGPKeyStore.publicKeyMaterial(from: binary) else {
                // Not a key the Swift parser reads (RSA, NIST curves, or
                // not a key at all); the Rust engine gets it either way.
                rustOnly.append((blobs.count - 1, url.lastPathComponent))
                continue
            }
            do {
                if let key = try Self.extractSecret(binary, passphrase: passphrase) {
                    decryption.append(key)
                } else {
                    // Public-only, or a secret key the Swift path can't
                    // use (an RSA encryption subkey under an Ed25519
                    // primary, say).
                    rustOnly.append((blobs.count - 1, url.lastPathComponent))
                }
            } catch PacketParserError.passphraseRequired {
                locked.append(url.lastPathComponent)
            } catch PacketParserError.wrongPassphrase {
                locked.append(url.lastPathComponent + " (wrong passphrase)")
            }
            // publicBlob (not the original) so recipient extraction sees
            // tag-14 public subkeys even for secret-only exports.
            loaded.append(KeyEntry(raw: material.publicBlob, infos: material.infos))
        }
        self.decryptionKeys = decryption
        self.entries = loaded
        self.rpgp = RpgpFallback(blobs: blobs, passphrase: passphrase)
        if !rustOnly.isEmpty {
            // These keys need rpgp anyway, so build it now; the load is
            // also what reports their lock state (one S2K per key, the
            // same cost the Swift path pays for its own locked keys).
            let states = rpgp.engine.blobLockStates()
            for file in rustOnly where file.index < states.count {
                switch states[file.index] {
                case .passphraseRequired:
                    locked.append(file.name)
                case .wrongPassphrase:
                    locked.append(file.name + " (wrong passphrase)")
                case .notSecret, .unprotected, .unlocked:
                    break
                }
            }
        }
        PGPKeyStore.lockedKeyFiles = locked
    }

    /// Try v4 extraction, then v6; passphrase errors propagate, structural
    /// mismatches (public-only blob, wrong version) return nil.
    private static func extractSecret(
        _ binary: Data, passphrase: String?
    ) throws -> Cv25519DecryptionKey? {
        do {
            return try OpenPGPPacketParser.cv25519DecryptionKey(
                fromSecretKey: binary, passphrase: passphrase
            )
        } catch PacketParserError.passphraseRequired {
            throw PacketParserError.passphraseRequired
        } catch PacketParserError.wrongPassphrase {
            throw PacketParserError.wrongPassphrase
        } catch {
            // Not a v4 secret blob; fall through to v6.
        }
        do {
            return try OpenPGPPacketParser.x25519DecryptionKey(
                fromV6SecretKey: binary, passphrase: passphrase
            )
        } catch PacketParserError.passphraseRequired {
            throw PacketParserError.passphraseRequired
        } catch PacketParserError.wrongPassphrase {
            throw PacketParserError.wrongPassphrase
        } catch {
            return nil
        }
    }

    // MARK: CryptoBackend

    func decrypt(ciphertext: Data) throws -> Data {
        guard !decryptionKeys.isEmpty else {
            return try rpgp.engine.decrypt(ciphertext: ciphertext)
        }
        do {
            return try nativeDecrypt(ciphertext)
        } catch let nativeError {
            // RSA or NIST recipients, or GnuPG's AEAD packets: hand the
            // entry to rpgp. It holds every key the Swift path has and
            // more, so when both fail its error is the one to show (an AEAD
            // entry for a locked key reads "no usable key", not "failed").
            let engine = rpgp.engine
            guard engine.hasSecretKeys() else { throw nativeError }
            return try engine.decrypt(ciphertext: ciphertext)
        }
    }

    private func nativeDecrypt(_ ciphertext: Data) throws -> Data {
        let binary: Data
        if let text = String(data: ciphertext, encoding: .utf8),
           text.contains("-----BEGIN") {
            binary = (try? OpenPGPPacketParser.dearmor(text)) ?? ciphertext
        } else {
            binary = ciphertext
        }
        do {
            let contents = try OpenPGPPacketParser.decryptMessageReturningInnerPackets(
                messageData: binary,
                decryptionKeys: decryptionKeys
            )
            return contents.literalData
        } catch PacketParserError.noMatchingKey {
            throw CryptoError.NoUsableKey
        } catch {
            throw CryptoError.DecryptionFailed
        }
    }

    func encrypt(plaintext: Data, recipients: [String]) throws -> Data {
        guard !recipients.isEmpty else {
            // pass stores always resolve a .gpg-id; empty means uninitialized.
            throw CryptoError.NoUsableKey
        }
        var targets: [Cv25519Recipient] = []
        for spec in recipients {
            // A recipient the Swift path can't resolve or encrypt to (RSA,
            // NIST curves, a key it didn't load) sends the whole entry to
            // rpgp, which encrypts to every recipient or throws; it never
            // drops one.
            guard let entry = resolve(spec) else {
                return try rustEncrypt(plaintext, recipients: recipients)
            }
            if let r = try? OpenPGPPacketParser.cv25519Recipient(fromPublicKey: entry.raw) {
                targets.append(r)
            } else if let r = try? OpenPGPPacketParser.x25519Recipient(fromV6PublicKey: entry.raw) {
                targets.append(r)
            } else {
                return try rustEncrypt(plaintext, recipients: recipients)
            }
        }
        // Never encrypt to fewer recipients than .gpg-id lists: every spec
        // resolved to a Curve25519 key above, or the whole entry went to
        // rpgp, which also refuses to drop one.
        do {
            return try OpenPGPPacketBuilder.buildEncryptedMessage(
                plaintext: plaintext,
                recipients: targets,
                armor: false // pass entries are binary .gpg
            )
        } catch {
            throw CryptoError.EncryptionFailed
        }
    }

    /// rpgp encryption, with its "no key matches" error localized the way
    /// the Swift path words it (rpgp's own text stays English).
    private func rustEncrypt(_ plaintext: Data, recipients: [String]) throws -> Data {
        let prefix = "No imported key matches "
        do {
            return try rpgp.engine.encrypt(plaintext: plaintext, recipients: recipients)
        } catch CryptoError.Unavailable(let reason) where reason.hasPrefix(prefix) {
            let spec = reason.dropFirst(prefix.count)
                .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            throw CryptoError.Unavailable(
                reason: L("No imported key matches \(spec) (fingerprint or 16-hex key ID)")
            )
        }
    }

    /// Match a `.gpg-id` line against known keys: uppercase-hex fingerprint
    /// (any key in the blob, primary or subkey), or 16-hex key ID. `0x`
    /// prefix and inner spaces tolerated.
    private func resolve(_ spec: String) -> KeyEntry? {
        let needle = spec
            .uppercased()
            .replacingOccurrences(of: "0X", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !needle.isEmpty else { return nil }
        return entries.first { entry in
            entry.infos.contains { info in
                let fp = info.fingerprintHex.uppercased()
                let kid = info.keyIDHex.uppercased()
                return fp == needle || kid == needle || fp.hasSuffix(needle) && needle.count >= 16
            }
        }
    }
}

enum PGPKeyStore {
    static var keyDirectory: URL {
        StorePaths.container.appendingPathComponent("pgp-keys", isDirectory: true)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: keyDirectory, withIntermediateDirectories: true
        )
    }

    /// Key files that couldn't be unlocked on the last engine load —
    /// Settings offers the passphrase prompt when this is non-empty.
    /// (Written on engine init from whichever thread loads the store;
    /// read from the UI. Simple last-write-wins is fine for a status list.)
    static var lockedKeyFiles: [String] = []

    static var hasKeys: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: keyDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return !files.isEmpty
    }

    /// Public-key packets for any key blob. A secret-only export (tags 5/7,
    /// the common `gpg --export-secret-keys` shape) carries no public-key
    /// packets, so derive them via the core's public-key derivation
    /// (v4 Ed25519/Cv25519). Returns the infos plus the binary blob that
    /// actually contains public packets — use that blob for recipient
    /// extraction, and the original for secret extraction.
    static func publicKeyMaterial(from binary: Data) -> (infos: [ParsedPublicKeyInfo], publicBlob: Data)? {
        if let infos = try? OpenPGPPacketParser.parseAllPublicKeys(from: Array(binary)),
           !infos.isEmpty {
            return (infos, binary)
        }
        guard
            let armored = try? OpenPGPPacketParser.transferablePublicKey(fromSecretKey: binary),
            let derived = try? OpenPGPPacketParser.dearmor(armored),
            let infos = try? OpenPGPPacketParser.parseAllPublicKeys(from: Array(derived)),
            !infos.isEmpty
        else { return nil }
        return (infos, derived)
    }

    /// A key file summarized for pickers: primary-key identity plus every
    /// fingerprint in the blob (subkeys included, for `.gpg-id` matching).
    struct KeyFileInfo: Identifiable {
        var id: String { file }
        let file: String
        let primaryFingerprint: String // uppercase hex
        let algorithm: String
        let isV6: Bool
    }

    /// Parse every imported key file into a picker-ready summary. Files that
    /// aren't OpenPGP keys are skipped silently.
    static func availableKeys() -> [KeyFileInfo] {
        ensureDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: keyDirectory, includingPropertiesForKeys: nil
        )) ?? []
        var out: [KeyFileInfo] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let raw = try? Data(contentsOf: url) else { continue }
            if let native = nativeKeyInfo(raw, file: url.lastPathComponent) {
                out.append(native)
            } else if let info = pgpKeyInfos(blob: raw).first, info.canEncrypt {
                // RSA and the other keys only the Rust engine reads. Before
                // 2.1 these were skipped, so a store keyed to RSA could not
                // be initialized ("Import a key file in Settings first").
                out.append(KeyFileInfo(
                    file: url.lastPathComponent,
                    primaryFingerprint: info.primaryFingerprint,
                    algorithm: info.algorithm,
                    isV6: info.isV6
                ))
            }
        }
        return out
    }

    private static func nativeKeyInfo(_ raw: Data, file: String) -> KeyFileInfo? {
        let binary: Data
        if let text = String(data: raw, encoding: .utf8), text.contains("-----BEGIN") {
            guard let dearmored = try? OpenPGPPacketParser.dearmor(text) else { return nil }
            binary = dearmored
        } else {
            binary = raw
        }
        guard
            let material = publicKeyMaterial(from: binary),
            let primary = material.infos.first
        else { return nil }
        return KeyFileInfo(
            file: file,
            primaryFingerprint: primary.fingerprintHex.uppercased(),
            algorithm: primary.algorithmName,
            isV6: primary.isV6
        )
    }
}

/// The Rust (rpgp) engine behind PGPonyEngine's fallback, built on first
/// use and then reused for the engine's lifetime. A box with its own lock
/// so PGPonyEngine keeps only `let` properties.
private final class RpgpFallback: @unchecked Sendable {
    private let blobs: [Data]
    private let passphrase: String?
    private let lock = NSLock()
    private var built: PgpEngine?

    init(blobs: [Data], passphrase: String?) {
        self.blobs = blobs
        self.passphrase = passphrase
    }

    var engine: PgpEngine {
        lock.lock()
        defer { lock.unlock() }
        if let built { return built }
        let engine = PgpEngine.fromKeyBlobs(blobs: blobs, passphrase: passphrase)
        built = engine
        return engine
    }
}
