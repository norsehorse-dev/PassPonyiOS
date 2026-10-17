import SwiftUI
import UniformTypeIdentifiers

/// Restore from a `.passpony` backup, shared by the Keys backup screen and
/// onboarding: file picker, then a recovery-code prompt, then the restore.
/// A mistyped code is caught by the code's check character before any
/// decrypting; a well-formed but wrong code keeps the prompt open.
struct BackupRestorer: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    var onResult: (String) -> Void

    @State private var pending: Data?
    @State private var code = ""
    @State private var dialogError: String?
    @State private var busy = false
    @State private var sshToConfirm: SshKey?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    onResult(L("That file couldn't be read."))
                    return
                }
                guard AgeIdentityStore.isPassphraseProtected(data) else {
                    onResult(BackupError.NotABackup.ponyMessage)
                    return
                }
                code = ""
                dialogError = nil
                pending = data
            }
            .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Recovery code", text: $code)
                                .font(.body.monospaced())
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .disabled(busy)
                        } footer: {
                            Text("Enter the recovery code you wrote down when you made this backup.")
                        }
                        if let dialogError {
                            Section { Text(dialogError).foregroundStyle(.red).font(.footnote) }
                        }
                        if busy {
                            Section { ProgressView() }
                        }
                    }
                    .navigationTitle("Restore backup")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { pending = nil }.disabled(busy)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Restore") { submit() }
                                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        }
                    }
                }
                .interactiveDismissDisabled(busy)
            }
            // The backup's SSH key differs from this app's: replacing it could
            // lock the app out of a host that only knows the current key.
            .confirmationDialog(
                "Replace this app's SSH key?",
                isPresented: Binding(get: { sshToConfirm != nil }, set: { if !$0 { sshToConfirm = nil } }),
                titleVisibility: .visible,
                presenting: sshToConfirm
            ) { key in
                Button("Replace", role: .destructive) {
                    sshToConfirm = nil
                    do {
                        try model.replaceSshKey(key)
                        onResult(L("The SSH key from the backup is now this app's key."))
                    } catch {
                        onResult(error.ponyMessage)
                    }
                }
                Button("Keep current key", role: .cancel) {
                    sshToConfirm = nil
                    onResult(L("Kept the current SSH key."))
                }
            } message: { _ in
                Text("The backup has a different SSH key from the one this app uses now. Git hosts that only know the current key will stop accepting this app if you replace it.")
            }
    }

    private func submit() {
        guard let data = pending else { return }
        let canonical: String
        do {
            canonical = try backupNormalizeRecoveryCode(input: code)
        } catch {
            dialogError = error.ponyMessage
            return
        }
        busy = true
        dialogError = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.restoreBackup(data, recoveryCode: canonical)
                pending = nil
                onResult(restoreSummary(result))
                sshToConfirm = result.sshKeyToConfirm
            } catch AgeIdentityStore.ImportError.wrongPassphrase {
                dialogError = L("That recovery code doesn't open this backup.")
            } catch {
                pending = nil
                onResult(error.ponyMessage)
            }
        }
    }
}

func restoreSummary(_ r: AppModel.RestoreResult) -> String {
    var parts: [String] = []
    if r.identitiesAdded > 0 { parts.append(L("\(r.identitiesAdded) age identities")) }
    if r.pgpKeysAdded > 0 { parts.append(L("\(r.pgpKeysAdded) PGP keys")) }
    if r.sshKeyRestored { parts.append(L("the SSH key")) }
    var message: String
    if !parts.isEmpty {
        message = L("Restored \(parts.joined(separator: ", ")).")
    } else if r.sshKeyToConfirm != nil {
        message = L("The backup's SSH key is different from this app's.")
    } else {
        message = L("Restored. Every key in the backup was already here.")
    }
    if r.unknownSections > 0 {
        message += " " + L("\(r.unknownSections) items from a newer version were skipped.")
    }
    return message
}

extension View {
    func backupRestorer(isPresented: Binding<Bool>, onResult: @escaping (String) -> Void) -> some View {
        modifier(BackupRestorer(isPresented: isPresented, onResult: onResult))
    }
}
