// Passkeys (2.0 rc3): which entries hold passkeys for which sites, so the
// system's passkey sheet can offer them before anything is unlocked or
// decrypted. Kept in the app group container so the app and the
// credential provider extension share it.
//
// One file per store format, one line per passkey:
// `rpId<TAB>entryName<TAB>credentialId<TAB>userHandle` (both as base64url).
// The account name iOS shows is the entry's name; usernames and keys stay
// inside the encrypted entries.

import AuthenticationServices
import Foundation

enum PasskeyIndex {
    struct Ref: Equatable {
        var rpId: String
        var entryName: String
        var credentialId: Data
        var userHandle: Data
    }

    private static let lock = NSLock()

    private static func url(_ format: StoreFormat) -> URL {
        StorePaths.container.appendingPathComponent(
            format == .passage ? "passkeys-passage.idx" : "passkeys-pass.idx"
        )
    }

    static func exists(_ format: StoreFormat) -> Bool {
        FileManager.default.fileExists(atPath: url(format).path)
    }

    static func all(_ format: StoreFormat) -> [Ref] {
        lock.lock()
        defer { lock.unlock() }
        return read(format)
    }

    static func forRpId(_ rpId: String, format: StoreFormat) -> [Ref] {
        all(format).filter { $0.rpId == rpId }
    }

    /// Replace every line for `entryName` with what its content holds now.
    static func updateEntry(_ entryName: String, content: Data?, format: StoreFormat) {
        lock.lock()
        defer { lock.unlock() }
        var refs = read(format).filter { $0.entryName != entryName }
        if let content { refs += self.refs(in: content, entryName: entryName) }
        write(refs, format: format)
    }

    static func renameEntry(from: String, to: String, format: StoreFormat) {
        lock.lock()
        defer { lock.unlock() }
        write(read(format).map { ref in
            var r = ref
            if r.entryName == from { r.entryName = to }
            return r
        }, format: format)
    }

    /// Rebuild from the whole store; entries that can't be decrypted right
    /// now are skipped rather than failing the rebuild.
    static func rebuild(store: PassStore, backend: CryptoBackend, format: StoreFormat) {
        var refs: [Ref] = []
        for entry in (try? store.entries()) ?? [] {
            guard var content = try? store.readEntry(name: entry.name, backend: backend) else { continue }
            refs += self.refs(in: content, entryName: entry.name)
            content.resetBytes(in: 0..<content.count)
        }
        lock.lock()
        defer { lock.unlock() }
        write(refs, format: format)
    }

    /// The identities iOS offers in the passkey sheet and QuickType bar.
    static func identities(format: StoreFormat) -> [ASPasskeyCredentialIdentity] {
        all(format).map { ref in
            ASPasskeyCredentialIdentity(
                relyingPartyIdentifier: ref.rpId,
                userName: ref.entryName,
                credentialID: ref.credentialId,
                userHandle: ref.userHandle,
                recordIdentifier: ref.entryName
            )
        }
    }

    private static func refs(in content: Data, entryName: String) -> [Ref] {
        entryPasskeys(content: content).map {
            Ref(rpId: $0.rpId, entryName: entryName, credentialId: $0.credentialId, userHandle: $0.userHandle)
        }
    }

    private static func read(_ format: StoreFormat) -> [Ref] {
        guard let text = try? String(contentsOf: url(format), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4,
                  let id = Data(base64URL: parts[2]),
                  let handle = Data(base64URL: parts[3])
            else { return nil }
            return Ref(rpId: parts[0], entryName: parts[1], credentialId: id, userHandle: handle)
        }
    }

    private static func write(_ refs: [Ref], format: StoreFormat) {
        var seen: [Ref] = []
        for r in refs where !seen.contains(r) { seen.append(r) }
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let text = seen.map {
            "\(clean($0.rpId))\t\(clean($0.entryName))\t\($0.credentialId.base64URL)\t\($0.userHandle.base64URL)\n"
        }.joined()
        try? Data(text.utf8).write(to: url(format), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension Data {
    /// Unpadded base64url, as WebAuthn and the passkey line use it.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
