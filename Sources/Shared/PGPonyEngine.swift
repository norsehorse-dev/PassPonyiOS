// Classic-pass (OpenPGP) crypto over NorseHorsePGPCore — the shared,
// auditable core. Covers Cv25519 v4 and X25519/Ed25519 v6 keys in software;
// RSA-keyed stores need the smartcard path (see the API proposal doc in
// PassPonyCore — software-RSA decrypt is deliberately absent from the core).
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

    /// Load every key file in `keyDirectory`. A protected secret key with no
    /// (or a wrong) passphrase surfaces as `CryptoError.Unavailable` naming
    /// the file — the unlock UX catches that and re-inits with a passphrase.
    init(keyDirectory: URL, passphrase: String? = nil) throws {
        var decryption: [Cv25519DecryptionKey] = []
        var loaded: [KeyEntry] = []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: keyDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in files where !url.hasDirectoryPath {
            guard let rawFile = try? Data(contentsOf: url) else { continue }
            let binary: Data
            if let text = String(data: rawFile, encoding: .utf8),
               text.contains("-----BEGIN") {
                guard let dearmored = try? OpenPGPPacketParser.dearmor(text) else { continue }
                binary = dearmored
            } else {
                binary = rawFile
            }
            guard let material = PGPKeyStore.publicKeyMaterial(from: binary) else {
                continue // not an OpenPGP key blob
            }
            do {
                if let key = try Self.extractSecret(binary, passphrase: passphrase) {
                    decryption.append(key)
                }
            } catch PacketParserError.passphraseRequired {
                throw CryptoError.Unavailable(
                    reason: "\(url.lastPathComponent) is passphrase-protected"
                )
            } catch PacketParserError.wrongPassphrase {
                throw CryptoError.Unavailable(
                    reason: "Wrong passphrase for \(url.lastPathComponent)"
                )
            }
            // publicBlob (not the original) so recipient extraction sees
            // tag-14 public subkeys even for secret-only exports.
            loaded.append(KeyEntry(raw: material.publicBlob, infos: material.infos))
        }
        self.decryptionKeys = decryption
        self.entries = loaded
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
        guard !decryptionKeys.isEmpty else { throw CryptoError.NoUsableKey }
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
            guard let entry = resolve(spec) else {
                throw CryptoError.Unavailable(
                    reason: "No imported key matches \(spec) (fingerprint or 16-hex key ID)"
                )
            }
            if let r = try? OpenPGPPacketParser.cv25519Recipient(fromPublicKey: entry.raw) {
                targets.append(r)
            } else if let r = try? OpenPGPPacketParser.x25519Recipient(fromV6PublicKey: entry.raw) {
                targets.append(r)
            } else {
                throw CryptoError.Unavailable(
                    reason: "Key for \(spec) has no usable encryption subkey (RSA keys need the smartcard path)"
                )
            }
        }
        // Never encrypt to fewer recipients than .gpg-id lists — resolution
        // above throws on the first miss, so reaching here means all matched.
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
            let binary: Data
            if let text = String(data: raw, encoding: .utf8), text.contains("-----BEGIN") {
                guard let dearmored = try? OpenPGPPacketParser.dearmor(text) else { continue }
                binary = dearmored
            } else {
                binary = raw
            }
            guard
                let material = publicKeyMaterial(from: binary),
                let primary = material.infos.first
            else { continue }
            out.append(KeyFileInfo(
                file: url.lastPathComponent,
                primaryFingerprint: primary.fingerprintHex.uppercased(),
                algorithm: primary.algorithmName,
                isV6: primary.isV6
            ))
        }
        return out
    }
}
