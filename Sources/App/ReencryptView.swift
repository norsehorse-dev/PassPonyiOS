import SwiftUI

/// Re-encrypt a subtree to its currently-resolved recipients — the in-app
/// mirror of `pass init -p` / `passage reencrypt -p`, with the plan's hard
/// requirement honored: a preview of exactly which files will be rewritten,
/// shown before anything is touched. Use after a recipients file changed
/// (synced from another device, or edited externally).
struct ReencryptView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var subpath = "" // "" = entire store
    @State private var targets: [String]?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scope", selection: $subpath) {
                        Text("Entire store").tag("")
                        ForEach(folders, id: \.self) { folder in
                            Text(folder).tag(folder)
                        }
                    }
                    .onChange(of: subpath) { _, _ in targets = nil }
                    Button("Preview") { preview() }
                        .disabled(busy)
                } footer: {
                    Text("Every entry in scope is decrypted and re-encrypted to the recipients its directory currently resolves to.")
                }

                if let targets {
                    Section("Will rewrite \(targets.count) entries") {
                        ForEach(targets, id: \.self) { name in
                            Text(name).font(.caption.monospaced())
                        }
                        Button("Re-encrypt now", role: .destructive) {
                            reencrypt()
                        }
                        .disabled(busy || targets.isEmpty)
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Re-encrypt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Distinct folder prefixes in the store, deepest included.
    private var folders: [String] {
        var out = Set<String>()
        for entry in model.entries {
            var components = entry.name.components(separatedBy: "/")
            components.removeLast()
            var path = ""
            for component in components {
                path = path.isEmpty ? component : path + "/" + component
                out.insert(path)
            }
        }
        return out.sorted()
    }

    private func preview() {
        guard let store = model.store else { return }
        do {
            targets = try store.reencryptTargets(subpath: subpath)
            message = nil
        } catch {
            message = error.ponyMessage
        }
    }

    private func reencrypt() {
        guard let store = model.store else { return }
        busy = true
        message = nil
        let scope = subpath
        let engine = model.engine
        let format = model.format
        Task.detached {
            do {
                let rewritten = try store.reencryptSubtree(subpath: scope, backend: engine)
                let ext = format == .passage ? "age" : "gpg"
                let files = rewritten.map { "\($0).\(ext)" }
                if !files.isEmpty {
                    try? model.git?.commitPaths(
                        paths: files,
                        message: commitMessageReencrypt(path: scope)
                    )
                }
                await MainActor.run {
                    message = L("Re-encrypted \(rewritten.count) entries.")
                    targets = nil
                    model.refresh()
                    busy = false
                }
            } catch {
                await MainActor.run {
                    message = error.ponyMessage
                    busy = false
                }
            }
        }
    }
}
