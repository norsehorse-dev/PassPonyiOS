import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [EntryRef] = []
    @Published var searchText = ""
    @Published var syncStatus: SyncStatus?
    @Published var lastError: String?

    let format: StoreFormat = .passage
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
            if try store.entries().isEmpty {
                try seedDemoStore(store)
            }
            #endif
            self.git = try? GitSync.open(root: root.path)
            refresh()
        } catch {
            lastError = String(describing: error)
        }
    }

    func refresh() {
        guard let store else { return }
        do {
            entries = try store.entries()
            syncStatus = try? git?.status()
            AutofillIdentities.sync(entries: entries)
        } catch {
            lastError = String(describing: error)
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
            lastError = String(describing: error)
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
            lastError = String(describing: error)
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
