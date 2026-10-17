// 2.0 rc4: devices sharing a passage store through its root
// `.age-recipients`, so syncing is all it takes. No secret key leaves a
// device; each one lists its own public key.
//
// - join: after a sync, clone or publish, this device's `age1...` keys are
//   added to the file (created if the store has none) and committed, so
//   everything saved from then on, here or anywhere, is readable by every
//   listed device.
// - pending: keys in the file this device has not been asked about. Older
//   entries are only readable by whoever wrote them, so a device that can
//   read them has to re-encrypt them for the new key. That step always
//   asks the person first (approve or remove): anyone who can push to the
//   repo can add a key, and silently re-encrypting to it would hand them
//   the store.
//
// Which keys this device has already been asked about is kept on the
// device, per store format, never in the repo. pass (OpenPGP) stores are
// left alone: `.gpg-id` stays the person's to edit.

import AgePonyCore
import Foundation

enum DeviceKeys {
    static let recipientsFile = ".age-recipients"

    private static func prefKey(_ format: StoreFormat) -> String {
        format == .passage ? "passpony.deviceKeys.seen.passage" : "passpony.deviceKeys.seen.pass"
    }

    private static func seen(_ format: StoreFormat) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: prefKey(format)) ?? [])
    }

    private static func markSeen(_ keys: [String], format: StoreFormat, replace: Bool = false) {
        let next = replace ? Set(keys) : seen(format).union(keys)
        UserDefaults.standard.set(Array(next).sorted(), forKey: prefKey(format))
    }

    /// This device's own `age1...` keys, from its identities file.
    static func ownKeys() -> [String] {
        guard let text = AgeIdentityStore.exportText() else { return [] }
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let identity = try? X25519Identity(ageIdentity: trimmed)
            else { continue }
            let recipient = identity.ageRecipient
            if !out.contains(recipient) { out.append(recipient) }
        }
        return out
    }

    /// List this device's keys in the root `.age-recipients` and commit.
    /// Returns true when the file changed, so the caller pushes.
    @discardableResult
    static func join(format: StoreFormat, store: PassStore, git: GitSync?) -> Bool {
        guard format == .passage else { return false }
        let own = ownKeys()
        guard !own.isEmpty else { return false }
        markSeen(own, format: format)
        let existing = (try? store.rootRecipients()) ?? nil
        let edit = recipientsAdd(existing: existing ?? "", keys: own)
        guard edit.changed > 0 else { return false }
        guard (try? store.setRootRecipients(text: edit.text)) != nil else { return false }
        try? git?.commitPaths(paths: [recipientsFile], message: commitMessageRecipientsAdd())
        return true
    }

    /// A store this device just cloned: whoever set it up already chose its
    /// recipients, and this device cannot read anything to re-encrypt yet,
    /// so the keys there now are not asked about.
    static func baseline(format: StoreFormat, store: PassStore) {
        guard format == .passage else { return }
        let listed = ((try? store.rootRecipients()) ?? nil).map { recipientsIn(text: $0) } ?? []
        markSeen(listed + ownKeys(), format: format, replace: true)
    }

    /// Keys in the file this device has not been asked about yet.
    static func pending(format: StoreFormat, store: PassStore?) -> [String] {
        guard format == .passage, let store else { return [] }
        let listed = ((try? store.rootRecipients()) ?? nil).map { recipientsIn(text: $0) } ?? []
        let known = seen(format).union(ownKeys())
        return listed.filter { !known.contains($0) }
    }

    /// The person recognized `key`: re-encrypt every entry this device can
    /// read to the current recipients, which include it, and commit.
    /// Entries this device cannot read are left for a device that can.
    static func approve(
        format: StoreFormat,
        store: PassStore,
        backend: CryptoBackend,
        git: GitSync?,
        key: String
    ) throws -> ReencryptReport {
        let report = try store.reencryptReadable(subpath: "", backend: backend)
        if !report.rewritten.isEmpty {
            let ext = format == .passage ? "age" : "gpg"
            try? git?.commitPaths(
                paths: report.rewritten.map { "\($0).\(ext)" },
                message: commitMessageReencrypt(path: "")
            )
        }
        markSeen([key], format: format)
        return report
    }

    /// The person did not recognize `key`: take it out of the file and
    /// commit, so nothing saved from now on is encrypted to it. Not marked
    /// as seen, so if it comes back it is asked about again.
    static func remove(format: StoreFormat, store: PassStore, git: GitSync?, key: String) throws {
        guard format == .passage, let existing = try store.rootRecipients() else { return }
        let edit = recipientsRemove(existing: existing, key: key)
        guard edit.changed > 0 else { return }
        try store.setRootRecipients(text: edit.text)
        try? git?.commitPaths(paths: [recipientsFile], message: commitMessageRecipientsRemove())
    }
}
