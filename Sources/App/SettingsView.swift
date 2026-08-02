import SwiftUI
import UniformTypeIdentifiers

/// Store settings: format switch (the plan's open decision, now a user
/// choice), OpenPGP key import for pass stores, and diagnostics basics.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var format = StorePaths.currentFormat
    @State private var keyFiles: [String] = []
    @State private var importing = false
    @State private var initializing = false
    @State private var gpgIDLines: [String] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Store format", selection: $format) {
                        Text("passage (age)").tag(StoreFormat.passage)
                        Text("pass (OpenPGP)").tag(StoreFormat.pass)
                    }
                    .onChange(of: format) { _, newValue in
                        StorePaths.currentFormat = newValue
                        model.openStore()
                    }
                } footer: {
                    Text("Each format keeps its own store. Switching never touches the other store's data.")
                }

                if format == .pass {
                    Section("OpenPGP keys") {
                        if keyFiles.isEmpty {
                            Text("No keys imported. A pass store needs at least a public key matching its .gpg-id (and the secret key to decrypt).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(keyFiles, id: \.self) { name in
                            Label(name, systemImage: "key")
                        }
                        .onDelete(perform: deleteKeys)
                        Button {
                            importing = true
                        } label: {
                            Label("Import key file…", systemImage: "square.and.arrow.down")
                        }
                    }

                    Section {
                        if gpgIDLines.isEmpty {
                            Button {
                                initializing = true
                            } label: {
                                Label("Initialize store with key…", systemImage: "wand.and.stars")
                            }
                            .disabled(keyFiles.isEmpty)
                        } else {
                            ForEach(gpgIDLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospaced())
                            }
                        }
                    } header: {
                        Text("Store recipients (.gpg-id)")
                    } footer: {
                        Text(gpgIDLines.isEmpty
                             ? "A pass store encrypts to the keys listed in its .gpg-id. Initialize once with your imported keys."
                             : "Re-keying a live store is the re-encrypt flow — coming with the subtree preview.")
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Core", value: coreVersion())
                    LabeledContent("Entries", value: "\(model.entries.count)")
                    if let st = model.syncStatus {
                        LabeledContent("Git", value: "↑\(st.ahead) ↓\(st.behind)\(st.dirty ? " (dirty)" : "")")
                    } else {
                        LabeledContent("Git", value: "not configured")
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.data, .text],
                allowsMultipleSelection: true
            ) { result in
                importKeys(result)
            }
            .sheet(isPresented: $initializing, onDismiss: { refreshKeys() }) {
                InitializeStoreView()
            }
            .onAppear { refreshKeys() }
        }
    }

    private func refreshKeys() {
        PGPKeyStore.ensureDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: PGPKeyStore.keyDirectory, includingPropertiesForKeys: nil
        )) ?? []
        keyFiles = files.map(\.lastPathComponent).sorted()
        let gpgID = StorePaths.storeRoot(for: .pass).appendingPathComponent(".gpg-id")
        gpgIDLines = (try? String(contentsOf: gpgID, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
    }

    private func importKeys(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        PGPKeyStore.ensureDirectory()
        var imported = 0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let dest = PGPKeyStore.keyDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                let data = try Data(contentsOf: url)
                try data.write(to: dest, options: [.completeFileProtection])
                imported += 1
            } catch {
                message = "Import failed for \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if imported > 0 {
            message = "Imported \(imported) key file\(imported == 1 ? "" : "s")."
        }
        refreshKeys()
        model.openStore()
    }

    private func deleteKeys(at offsets: IndexSet) {
        for index in offsets {
            let url = PGPKeyStore.keyDirectory.appendingPathComponent(keyFiles[index])
            try? FileManager.default.removeItem(at: url)
        }
        refreshKeys()
        model.openStore()
    }
}
