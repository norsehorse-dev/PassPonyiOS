import AgePonyCore
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [EntryRef] = []
    @Published var searchText = ""
    @Published var syncStatus: SyncStatus?
    @Published var lastError: String?
    /// 2.0 rc4: keys another device added to `.age-recipients` that this
    /// one has not been asked about. The Sync screen asks, one at a time.
    @Published var pendingDeviceKeys: [String] = []

    /// Lives here rather than in StoreListView so the Settings sheet's
    /// presentation state sits outside any re-keyed subtree and can never
    /// be dropped by a language-change rebuild.
    @Published var showingSettings = false

    /// In-app language override ("" follows the system). Published so the
    /// root view rebuilds the moment the Settings picker changes it; the
    /// didSet persists the choice and re-points this process's lookups.
    @Published var language: String = AppLanguage.current {
        didSet {
            guard language != oldValue else { return }
            AppLanguage.select(language)
        }
    }

    var format: StoreFormat { StorePaths.currentFormat }
    private(set) var store: PassStore?
    private(set) var git: GitSync?

    var engine: CryptoBackend { EngineProvider.engine(for: format) }

    var visibleEntries: [EntryRef] {
        let base = entries.filter { !$0.hidden }
        guard !searchText.isEmpty else { return base }
        let needle = searchText.lowercased()
        return base.filter { $0.name.lowercased().contains(needle) }
    }

    func openStore() {
        do {
            let root = StorePaths.storeRoot
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            let store = try PassStore.open(root: root.path, format: format)
            self.store = store
            #if DEBUG
            // Demo seeding is passage-only; pass stores start from imported
            // keys and a real .gpg-id. Held back until the tour is done so
            // the onboarding import/try slides see a genuinely empty store.
            if format == .passage, try store.entries().isEmpty,
               UserDefaults.standard.bool(forKey: "passpony.onboardingCompleted") {
                try seedDemoStore(store)
                if ProcessInfo.processInfo.arguments.contains("-seedDemoStore") {
                    Self.giveDemoStoreARemote(root: root, format: format)
                    self.store = try PassStore.open(root: root.path, format: format)
                }
            }
            #endif
            self.git = try? GitSync.open(root: root.path)
            refresh()
            rebuildPasskeyIndex()
        } catch {
            lastError = error.ponyMessage
        }
    }

    func refresh() {
        guard let store else { return }
        do {
            entries = try store.entries()
            syncStatus = try? git?.status()
            AutofillIdentities.sync(entries: entries)
        } catch {
            lastError = error.ponyMessage
        }
    }

    func readEntry(_ name: String) throws -> Data {
        guard let store else { throw StoreError.NoStore }
        return try store.readEntry(name: name, backend: engine)
    }

    func saveEntry(name: String, content: Data, isNew: Bool) {
        guard let store else { return }
        do {
            try store.writeEntry(name: name, content: content, backend: engine)
            let file = "\(name).\(format == .passage ? "age" : "gpg")"
            let message = isNew ? commitMessageAdd(name: name)
                                : commitMessageEdit(name: name)
            try? git?.commitPaths(paths: [file], message: message)
            PasskeyIndex.updateEntry(name, content: content, format: format)
            refresh()
        } catch {
            lastError = error.ponyMessage
        }
    }

    /// Import any logins Umbra handed off via the shared inbox: encrypt
    /// each into the store, commit, and clear it. Writing needs only the
    /// store's recipients (public keys), so this runs without an unlock.
    func importInbox() {
        guard let store, !CredentialInbox.isEmpty else { return }
        let pending = CredentialInbox.pending()
        guard !pending.isEmpty else { return }

        var imported = false
        let ext = format == .passage ? "age" : "gpg"
        for cred in pending {
            let name = uniqueEntryName(base: "web/\(cred.host)")
            var body = cred.password + "\n"
            if !cred.username.isEmpty { body += "username: \(cred.username)\n" }
            if !cred.url.isEmpty { body += "url: \(cred.url)\n" }
            do {
                try store.writeEntry(name: name, content: Data(body.utf8), backend: engine)
                try? git?.commitPaths(paths: ["\(name).\(ext)"], message: commitMessageAdd(name: name))
                CredentialInbox.remove(id: cred.id)
                imported = true
            } catch {
                // Leave the item in the inbox to retry on the next launch.
                lastError = error.ponyMessage
            }
        }
        if imported { refresh() }
    }

    /// A store path that does not collide with an existing entry.
    private func uniqueEntryName(base: String) -> String {
        guard let store else { return base }
        if !store.hasEntry(name: base) { return base }
        var i = 2
        while store.hasEntry(name: "\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    /// Move/rename. Core semantics: passage always re-encrypts the moved
    /// entry; pass re-encrypts only when the resolved key set differs.
    func moveEntry(from: String, to: String) -> Bool {
        guard let store else { return false }
        do {
            try store.moveEntry(from: from, to: to, backend: engine)
            let ext = format == .passage ? "age" : "gpg"
            try? git?.commitPaths(
                paths: ["\(from).\(ext)", "\(to).\(ext)"],
                message: commitMessageRename(from: from, to: to)
            )
            PasskeyIndex.renameEntry(from: from, to: to, format: format)
            refresh()
            return true
        } catch {
            lastError = error.ponyMessage
            return false
        }
    }

    // MARK: - 2.0 rc1: HOTP, Authenticator import, keys backup

    func hasEntry(_ name: String) -> Bool {
        store?.hasEntry(name: name) ?? false
    }

    private func fileName(_ name: String) -> String {
        "\(name).\(format == .passage ? "age" : "gpg")"
    }

    /// Next HOTP code, pass-otp style: the counter is advanced and the
    /// entry written and committed ("Increment HOTP counter for <name>.")
    /// before the code is returned, so a code is never shown whose counter
    /// was not saved.
    func advanceHotp(name: String, content: Data) throws -> HotpAdvance {
        guard let store else { throw StoreError.NoStore }
        let next = try entryHotpNext(content: content)
        try store.writeEntry(name: name, content: next.content, backend: engine)
        try? git?.commitPaths(paths: [fileName(name)], message: commitMessageHotpIncrement(name: name))
        refresh()
        return next
    }

    /// Write OTP-only entries (the URI as the whole entry, what
    /// `pass otp insert` writes), one commit each with pass-otp's message.
    /// Returns how many were written before any failure, which is rethrown.
    func addOtpEntries(_ items: [(name: String, uri: String)]) throws -> Int {
        guard let store else { throw StoreError.NoStore }
        var written = 0
        defer { refresh() }
        for item in items {
            try store.writeEntry(name: item.name, content: Data("\(item.uri)\n".utf8), backend: engine)
            try? git?.commitPaths(paths: [fileName(item.name)], message: commitMessageOtpAdd(name: item.name))
            written += 1
        }
        return written
    }

    /// Import an identities file (plain or passphrase-protected) for the
    /// passage store and reopen so entries waiting on that key decrypt. The
    /// scrypt work runs off the main actor.
    func importAgeIdentities(_ data: Data, passphrase: String?) async throws -> AgeIdentityStore.ImportResult {
        let result = try await Task.detached(priority: .userInitiated) {
            try AgeIdentityStore.importIdentitiesFile(data, passphrase: passphrase)
        }.value
        openStore()
        return result
    }

    /// An encrypted `.passpony` backup of every key on this device: the age
    /// identities file and each file in pgp-keys/, encrypted to the
    /// canonical recovery code (see PassPonyCore docs/BACKUP.md).
    func buildBackup(recoveryCode: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            var sections: [BackupSection] = []
            if let text = AgeIdentityStore.exportText() {
                sections.append(BackupSection(kind: backupKindAgeIdentities(), name: "", data: Data(text.utf8)))
            }
            if let key = SshKeyStore.load() {
                sections.append(BackupSection(kind: backupKindSshPrivateKey(), name: "", data: Data(key.privateKey.utf8)))
            }
            let keyFiles = (try? FileManager.default.contentsOfDirectory(
                at: PGPKeyStore.keyDirectory, includingPropertiesForKeys: nil
            )) ?? []
            for url in keyFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let data = try? Data(contentsOf: url) {
                    sections.append(BackupSection(kind: backupKindPgpSecretKey(), name: url.lastPathComponent, data: data))
                }
            }
            var plaintext = backupEncode(sections: sections)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            return try Age.encrypt(plaintext: plaintext, passphrase: recoveryCode)
        }.value
    }

    struct RestoreResult {
        var identitiesAdded = 0
        var identitiesPresent = 0
        var pgpKeysAdded = 0
        var pgpKeysPresent = 0
        var unknownSections = 0
        /// The backup's SSH key became this app's key (it had none).
        var sshKeyRestored = false
        /// The backup's SSH key differs from the one this app has; the
        /// caller asks before `replaceSshKey`. Nothing was changed yet.
        var sshKeyToConfirm: SshKey?
    }

    /// Restore a `.passpony` backup with the canonical recovery code. Age
    /// identities are merged, never replacing what is here; a PGP key file
    /// is added unless an identical one is present, and a different file
    /// under the same name is kept beside it. A wrong code or a damaged
    /// backup throws before anything is written.
    func restoreBackup(_ data: Data, recoveryCode: String) async throws -> RestoreResult {
        let result = try await Task.detached(priority: .userInitiated) { () throws -> RestoreResult in
            var plaintext = try AgeIdentityStore.decryptWithPassphrase(data, passphrase: recoveryCode)
            let sections: [BackupSection]
            do {
                sections = try backupDecode(plaintext: plaintext)
            } catch {
                plaintext.resetBytes(in: 0..<plaintext.count)
                throw error
            }
            plaintext.resetBytes(in: 0..<plaintext.count)
            var r = RestoreResult()
            for section in sections {
                switch section.kind {
                case backupKindAgeIdentities():
                    let text = String(decoding: section.data, as: UTF8.self)
                    let imported = try AgeIdentityStore.importIdentities(text)
                    r.identitiesAdded += imported.added
                    r.identitiesPresent += imported.alreadyPresent
                case backupKindPgpSecretKey():
                    if try AppModel.restorePgpKey(name: section.name, data: section.data) {
                        r.pgpKeysAdded += 1
                    } else {
                        r.pgpKeysPresent += 1
                    }
                case backupKindSshPrivateKey():
                    guard let restored = try? sshImportKey(data: section.data, passphrase: nil) else {
                        r.unknownSections += 1
                        continue
                    }
                    let current = SshKeyStore.load()
                    if current == nil && !SshKeyStore.hasKey {
                        try SshKeyStore.save(restored)
                        r.sshKeyRestored = true
                    } else if current?.fingerprint != restored.fingerprint {
                        r.sshKeyToConfirm = restored
                    }
                default:
                    r.unknownSections += 1
                }
            }
            return r
        }.value
        if result.identitiesAdded == 0, result.identitiesPresent > 0,
           result.identitiesPresent == AgeIdentityStore.identityCount() {
            KeyBackupState.markBackedUp()
        }
        openStore()
        return result
    }

    /// True when written, false when an identical file was already there.
    nonisolated private static func restorePgpKey(name: String, data: Data) throws -> Bool {
        PGPKeyStore.ensureDirectory()
        let safe = URL(fileURLWithPath: name.isEmpty ? "restored-key.asc" : name).lastPathComponent
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var target = PGPKeyStore.keyDirectory.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            if (try? Data(contentsOf: target)) == data { return false }
            let candidate = ext.isEmpty ? "\(base)-restored-\(n)" : "\(base)-restored-\(n).\(ext)"
            target = PGPKeyStore.keyDirectory.appendingPathComponent(candidate)
            n += 1
        }
        try data.write(to: target, options: [.completeFileProtection])
        return true
    }

    /// The user chose the backup's SSH key over the one this app had.
    func replaceSshKey(_ key: SshKey) throws {
        try SshKeyStore.save(key)
    }

    /// Pin an SSH host's key after the user confirmed its fingerprint
    /// (from `GitError.UnknownHostKey`); the caller then retries.
    func trustHost(_ host: String, key: HostKey) throws {
        try SshKeyStore.trust(host: host, key: key)
    }

    // MARK: - 2.0 rc4: devices sharing a store

    /// List this device in `.age-recipients` (committing and pushing when
    /// that changed anything), then look for keys other devices added. A
    /// failed push leaves the commit for the next Push; the sync itself
    /// already succeeded.
    func joinRecipients() async {
        guard let store else { return }
        let git = self.git
        let format = self.format
        let pending = await Task.detached(priority: .userInitiated) { () -> [String] in
            if DeviceKeys.join(format: format, store: store, git: git) {
                git?.setSsh(ssh: SshKeyStore.config())
                try? git?.push()
            }
            return DeviceKeys.pending(format: format, store: store)
        }.value
        pendingDeviceKeys = pending
        refresh()
    }

    /// After a clone: the keys already listed are the store's own choice.
    func joinAfterClone() async {
        if let store { DeviceKeys.baseline(format: format, store: store) }
        await joinRecipients()
    }

    /// The person recognized `key`: re-encrypt what this device can read,
    /// commit, push.
    func approveDeviceKey(_ key: String) async throws -> ReencryptReport {
        guard let store else { throw StoreError.NoStore }
        let git = self.git
        let format = self.format
        let backend = engine
        let (report, pending) = try await Task.detached(priority: .userInitiated) { () -> (ReencryptReport, [String]) in
            let report = try DeviceKeys.approve(format: format, store: store, backend: backend, git: git, key: key)
            if !report.rewritten.isEmpty {
                git?.setSsh(ssh: SshKeyStore.config())
                try git?.push()
            }
            return (report, DeviceKeys.pending(format: format, store: store))
        }.value
        pendingDeviceKeys = pending
        refresh()
        return report
    }

    /// The person did not recognize `key`: take it out of the file, push.
    func removeDeviceKey(_ key: String) async throws {
        guard let store else { throw StoreError.NoStore }
        let git = self.git
        let format = self.format
        let pending = try await Task.detached(priority: .userInitiated) { () -> [String] in
            try DeviceKeys.remove(format: format, store: store, git: git, key: key)
            git?.setSsh(ssh: SshKeyStore.config())
            try git?.push()
            return DeviceKeys.pending(format: format, store: store)
        }.value
        pendingDeviceKeys = pending
        refresh()
    }

    /// "Later": stop asking until the next sync.
    func deferDeviceKeys() {
        pendingDeviceKeys = []
    }

    // MARK: - 2.0 rc3: passkeys

    /// Rebuild the passkey index from every entry, off the main actor, then
    /// re-register identities with iOS. Runs on every store open, which
    /// covers a clone, a format switch and a key import (entries that only
    /// just became readable), and after a sync brings in changes.
    func rebuildPasskeyIndex() {
        let format = self.format
        Task.detached(priority: .utility) {
            let root = StorePaths.storeRoot(for: format).path
            guard let store = try? PassStore.open(root: root, format: format) else { return }
            PasskeyIndex.rebuild(store: store, backend: EngineProvider.engine(for: format), format: format)
            await MainActor.run { self.refresh() }
        }
    }

    /// Delete one passkey from an entry: rewrite the entry without that
    /// line, commit, update the index. Returns the new content so the
    /// detail screen shows it without decrypting again.
    func removePasskey(name: String, content: Data, credentialId: Data) throws -> Data {
        guard let store else { throw StoreError.NoStore }
        let next = entryRemovePasskey(content: content, credentialId: credentialId)
        try store.writeEntry(name: name, content: next, backend: engine)
        try? git?.commitPaths(paths: [fileName(name)], message: commitMessagePasskeyRemove(name: name))
        PasskeyIndex.updateEntry(name, content: next, format: format)
        refresh()
        return next
    }

    func markKeysBackedUp() {
        KeyBackupState.markBackedUp()
        objectWillChange.send()
    }

    func deleteEntry(_ name: String) {
        guard let store else { return }
        do {
            try store.removeEntry(name: name)
            let file = "\(name).\(format == .passage ? "age" : "gpg")"
            try? git?.commitPaths(paths: [file], message: commitMessageRemove(name: name))
            PasskeyIndex.updateEntry(name, content: nil, format: format)
            refresh()
        } catch {
            lastError = error.ponyMessage
        }
    }

    #if DEBUG
    /// App Store screenshots: make the demo store a git clone with nothing
    /// to push and an example SSH remote, so Sync shows a configured store.
    /// The store is committed in a scratch folder, cloned into place (which
    /// sets up the tracking branch), then pointed at a remote that is never
    /// contacted. On any failure the plain demo store is put back.
    private static func giveDemoStoreARemote(root: URL, format: StoreFormat) {
        let fm = FileManager.default
        let origin = StorePaths.container.appendingPathComponent("demo-origin", isDirectory: true)
        try? fm.removeItem(at: origin)
        do {
            try fm.moveItem(at: root, to: origin)
            _ = try GitSync.`init`(root: origin.path, format: format)
            _ = try GitSync.cloneWithSsh(url: origin.path, dest: root.path, depth: nil, ssh: SshKeyStore.config())
            try GitSync.open(root: root.path).setRemote(url: "git@git.example.com:pony/passwords.git")
        } catch {
            if !fm.fileExists(atPath: root.path) { try? fm.moveItem(at: origin, to: root) }
        }
    }

    /// Screenshot-grade demo store: enough folders and entries to look
    /// lived-in, TOTP on several so the ring shows, usernames and urls on
    /// most. Every credential is fake. DEBUG builds only, passage only,
    /// seeded once into an empty store after the tour completes.
    private func seedDemoStore(_ store: PassStore) throws {
        let demo: [(String, String)] = [
            ("web/github.com", "tr0ut-mantle-vivid-42\nusername: pony\nurl: github.com\notpauth://totp/GitHub:pony?secret=JBSWY3DPEHPK3PXP&issuer=GitHub\n"),
            ("web/gitlab.com", "brindle-ox-cardigan-7\nusername: pony\nurl: gitlab.com\n"),
            ("web/google.com", "quartz-lantern-mirth-19\nusername: pony.rider\notpauth://totp/Google:pony.rider?secret=NBSWY3DPO5XXE3DE&issuer=Google\n"),
            ("web/amazon.com", "saddle-comet-birch-88\nusername: pony@example.com\nurl: amazon.com\n"),
            ("web/netflix.com", "velvet-abacus-north-3\nusername: pony@example.com\n"),
            ("web/reddit.com", "gable-onyx-pretzel-51\nusername: norsehorse\n"),
            ("web/wikipedia.org", "ember-latch-copper-24\nusername: NorseHorse\n"),
            ("mail/fastmail.com", "battery-staple-orchard-6\nusername: pony@example.com\notpauth://totp/Fastmail:pony?secret=MFRGGZDFMZTWQ2LK&issuer=Fastmail\n"),
            ("mail/proton.me", "walnut-frost-gallop-77\nusername: pony@proton.me\n"),
            ("finance/paypal.com", "cinder-maple-quill-30\nusername: pony@example.com\notpauth://totp/PayPal:pony?secret=JBSWY3DPEHPK3PXQ&issuer=PayPal\n"),
            ("finance/wise.com", "harbor-tulip-anvil-12\nusername: pony@example.com\n"),
            ("finance/bank.example", "hunter2-but-much-longer\nurl: bank.example\nnote: ask branch for wire limits\n"),
            ("work/vpn", "juniper-cobalt-relay-9\nusername: ppony\n"),
            ("work/vpn-2fa", "otpauth://totp/Work%20VPN:ppony?secret=JBSWY3DPEHPK3PXQ&issuer=Work%20VPN\n"),
            ("work/slack.com", "pommel-drift-signal-64\nusername: pony@example.com\nurl: norsehorse.slack.com\n"),
            ("work/jira.example.com", "griffin-mortar-plume-28\nusername: ppony\n"),
            ("wifi/home", "pony-passphrase-9000\n"),
            ("wifi/office", "stable-gateway-4242\n"),
            ("dev/registry.example.com", "tarpit-nimbus-octave-55\nusername: norsehorse-dev\n"),
        ]
        for (name, content) in demo {
            var bytes = Data(content.utf8)
            // A passkey for the GitHub entry, so the passkeys section shows
            // up in screenshots; made like a real registration.
            if name == "web/github.com" {
                let key = P256.Signing.PrivateKey()
                let point = key.publicKey.rawRepresentation
                if let passkey = try? passkeyRegister(
                    rpId: "github.com",
                    userHandle: Data("pony".utf8),
                    username: "pony",
                    userDisplayName: "pony",
                    keyPkcs8: key.derRepresentation,
                    x: Data(point.prefix(32)),
                    y: Data(point.suffix(32)),
                    userVerified: true
                ) {
                    bytes = entryAddPasskey(content: bytes, value: passkey.value)
                }
            }
            try store.writeEntry(name: name, content: bytes, backend: engine)
        }
    }
    #endif
}
