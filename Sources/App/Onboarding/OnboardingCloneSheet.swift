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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://user:token@host/you/store.git", text: $url)
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
                _ = try GitSync.cloneFrom(url: target, dest: tmp.path, depth: nil)
                let root = StorePaths.storeRoot
                try? FileManager.default.removeItem(at: root)
                try FileManager.default.moveItem(at: tmp, to: root)
                await MainActor.run {
                    model.openStore()
                    busy = false
                    dismiss()
                    onCloned()
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
