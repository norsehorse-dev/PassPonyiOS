import SwiftUI

/// `pass init`, app-shaped: choose one or more imported keys and write the
/// store's root `.gpg-id` with their primary fingerprints. Offered only when
/// no `.gpg-id` exists yet — changing the key set of a live store is the
/// re-encrypt-subtree flow (preview + rewrite), which lands separately.
struct InitializeStoreView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var keys: [PGPKeyStore.KeyFileInfo] = []
    @State private var selected: Set<String> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if keys.isEmpty {
                        Text("Import a key file in Settings first.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(keys) { key in
                        Button {
                            toggle(key)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.file)
                                        .foregroundStyle(.primary)
                                    Text("\(key.algorithm)\(key.isV6 ? " (v6)" : "") · \(shortFingerprint(key.primaryFingerprint))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected.contains(key.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Encrypt new entries to")
                } footer: {
                    Text("Writes the selected keys' fingerprints to the store's .gpg-id — the same file pass init creates. Every entry saved afterward is encrypted to all of them.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Initialize store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Initialize") { initialize() }
                        .disabled(selected.isEmpty)
                }
            }
            .onAppear { keys = PGPKeyStore.availableKeys() }
        }
    }

    private func toggle(_ key: PGPKeyStore.KeyFileInfo) {
        if selected.contains(key.id) {
            selected.remove(key.id)
        } else {
            selected.insert(key.id)
        }
    }

    private func shortFingerprint(_ fp: String) -> String {
        fp.count > 16 ? "…" + fp.suffix(16) : fp
    }

    private func initialize() {
        let root = StorePaths.storeRoot(for: .pass)
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            let fingerprints = keys
                .filter { selected.contains($0.id) }
                .map(\.primaryFingerprint)
            let content = fingerprints.joined(separator: "\n") + "\n"
            let gpgID = root.appendingPathComponent(".gpg-id")
            guard !FileManager.default.fileExists(atPath: gpgID.path) else {
                error = "Store already has a .gpg-id — re-keying comes with the re-encrypt flow."
                return
            }
            try Data(content.utf8).write(to: gpgID, options: [.completeFileProtection])
            model.openStore()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
