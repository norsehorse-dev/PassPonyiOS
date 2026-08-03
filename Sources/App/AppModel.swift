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
    private func seedDemoStore(_ store: PassStore) throws {
        let demo: [(String, String)] = [
            ("web/github.com", "correct-horse\nusername: kevin\nurl: github.com\notpauth://totp/GitHub:kevin?secret=JBSWY3DPEHPK3PXP&issuer=GitHub\n"),
            ("web/fastmail.com", "battery-staple\nusername: kevin@example.com\n"),
            ("finance/bank.example", "hunter2-but-longer\nurl: bank.example\nnote: ask branch for wire limits\n"),
            ("wifi/home", "pony-passphrase-9000\n"),
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
