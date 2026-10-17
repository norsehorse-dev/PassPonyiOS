import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [EntryRef] = []
    @Published var searchText = ""
    @Published var syncStatus: SyncStatus?
    @Published var lastError: String?

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
            }
            #endif
            self.git = try? GitSync.open(root: root.path)
            refresh()
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
            refresh()
            return true
        } catch {
            lastError = error.ponyMessage
            return false
        }
    }

    func deleteEntry(_ name: String) {
        guard let store else { return }
        do {
            try store.removeEntry(name: name)
            let file = "\(name).\(format == .passage ? "age" : "gpg")"
            try? git?.commitPaths(paths: [file], message: commitMessageRemove(name: name))
            refresh()
        } catch {
            lastError = error.ponyMessage
        }
    }

    #if DEBUG
    /// Screenshot-grade demo store: enough folders and entries to look
    /// lived-in, TOTP on several so the ring shows, usernames and urls on
    /// most. Every credential is fake. DEBUG builds only, passage only,
    /// seeded once into an empty store after the tour completes.
    private func seedDemoStore(_ store: PassStore) throws {
        let demo: [(String, String)] = [
            ("web/github.com", "tr0ut-mantle-vivid-42\nusername: kevin\nurl: github.com\notpauth://totp/GitHub:kevin?secret=JBSWY3DPEHPK3PXP&issuer=GitHub\n"),
            ("web/gitlab.com", "brindle-ox-cardigan-7\nusername: kevin\nurl: gitlab.com\n"),
            ("web/google.com", "quartz-lantern-mirth-19\nusername: kevin.stewart\notpauth://totp/Google:kevin.stewart?secret=NBSWY3DPO5XXE3DE&issuer=Google\n"),
            ("web/amazon.com", "saddle-comet-birch-88\nusername: kevin@example.com\nurl: amazon.com\n"),
            ("web/netflix.com", "velvet-abacus-north-3\nusername: kevin@example.com\n"),
            ("web/reddit.com", "gable-onyx-pretzel-51\nusername: norsehorse\n"),
            ("web/wikipedia.org", "ember-latch-copper-24\nusername: NorseHorse\n"),
            ("mail/fastmail.com", "battery-staple-orchard-6\nusername: kevin@example.com\notpauth://totp/Fastmail:kevin?secret=MFRGGZDFMZTWQ2LK&issuer=Fastmail\n"),
            ("mail/proton.me", "walnut-frost-gallop-77\nusername: kevin@proton.me\n"),
            ("finance/paypal.com", "cinder-maple-quill-30\nusername: kevin@example.com\notpauth://totp/PayPal:kevin?secret=JBSWY3DPEHPK3PXQ&issuer=PayPal\n"),
            ("finance/wise.com", "harbor-tulip-anvil-12\nusername: kevin@example.com\n"),
            ("finance/bank.example", "hunter2-but-much-longer\nurl: bank.example\nnote: ask branch for wire limits\n"),
            ("work/vpn", "juniper-cobalt-relay-9\nusername: kstewart\n"),
            ("work/vpn-2fa", "otpauth://totp/Work%20VPN:kstewart?secret=JBSWY3DPEHPK3PXQ&issuer=Work%20VPN\n"),
            ("work/slack.com", "pommel-drift-signal-64\nusername: kevin@example.com\nurl: norsehorse.slack.com\n"),
            ("work/jira.example.com", "griffin-mortar-plume-28\nusername: kstewart\n"),
            ("wifi/home", "pony-passphrase-9000\n"),
            ("wifi/office", "stable-gateway-4242\n"),
            ("dev/registry.example.com", "tarpit-nimbus-octave-55\nusername: norsehorse-dev\n"),
        ]
        for (name, content) in demo {
            try store.writeEntry(
                name: name,
                content: Data(content.utf8),
                backend: engine
            )
        }
    }
    #endif
}
