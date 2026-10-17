import SwiftUI

/// Minimal clone form for onboarding: URL in, clone into a scratch
/// directory, swap into place, reopen the store. Mirrors SyncView's clone
/// section (a failed clone never harms the current store).
struct OnboardingCloneSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onCloned: () -> Void

    @State private var url = ""
    @State private var busy = false
    @State private var error: String?
    @State private var hostPrompt: HostPrompt?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://user:token@host/you/store.git or git@host:you/store.git", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Clone") { clone() }
                        .disabled(url.isEmpty || busy)
                } footer: {
                    Text("The clone lands in a scratch area first — a failed clone leaves the current store untouched. On success it replaces the current store for this format. Decrypting cloned entries still needs the matching key: identities file for passage, imported OpenPGP key for pass.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Clone existing store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(busy)
            .hostKeyTrust($hostPrompt) { prompt in
                do {
                    try model.trustHost(prompt.host, key: prompt.key)
                } catch {
                    self.error = error.ponyMessage
                    return
                }
                clone()
            } onCancel: {
                error = L("Not connected. The host wasn't trusted.")
            }
        }
    }

    private func clone() {
        busy = true
        error = nil
        let target = url
        Task.detached {
            do {
                let tmp = StorePaths.container.appendingPathComponent("clone-tmp")
                try? FileManager.default.removeItem(at: tmp)
                _ = try GitSync.cloneWithSsh(url: target, dest: tmp.path, depth: nil, ssh: SshKeyStore.config())
                let root = StorePaths.storeRoot
                try? FileManager.default.removeItem(at: root)
                try FileManager.default.moveItem(at: tmp, to: root)
                await MainActor.run { model.openStore() }
                await model.joinAfterClone()
                await MainActor.run {
                    busy = false
                    dismiss()
                    onCloned()
                }
            } catch GitError.UnknownHostKey(let host, let key) {
                await MainActor.run {
                    busy = false
                    hostPrompt = HostPrompt(host: host, key: key, retry: {})
                }
            } catch {
                await MainActor.run {
                    self.error = error.ponyMessage
                    busy = false
                }
            }
        }
    }
}
