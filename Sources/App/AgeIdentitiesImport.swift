import SwiftUI
import UniformTypeIdentifiers

/// The age identities import shared by Settings and onboarding: file
/// picker, then (only when the picked file is age-encrypted, as gopass's
/// age backend writes `identities`) a passphrase prompt, then the same
/// validation a plaintext file gets. Imported identities are added to the
/// ones already here (2.0), never replacing them.
struct AgeIdentitiesImporter: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    var onResult: (String) -> Void

    @State private var pending: Data?
    @State private var passphrase = ""
    @State private var dialogError: String?
    @State private var busy = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.data, .text]) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    onResult(L("That file has no usable age identity."))
                    return
                }
                if AgeIdentityStore.isPassphraseProtected(data) {
                    passphrase = ""
                    dialogError = nil
                    pending = data
                } else {
                    Task { await run(data, passphrase: nil) }
                }
            }
            .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                NavigationStack {
                    Form {
                        Section {
                            SecureField("Passphrase", text: $passphrase)
                                .disabled(busy)
                        } footer: {
                            Text("Enter the passphrase this identities file was encrypted with, for example the one gopass asked for. It is only used to decrypt the file on this device.")
                        }
                        if let dialogError {
                            Section { Text(dialogError).foregroundStyle(.red).font(.footnote) }
                        }
                        if busy {
                            Section { ProgressView() }
                        }
                    }
                    .navigationTitle("Identities file is encrypted")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { pending = nil }.disabled(busy)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Unlock") {
                                if let data = pending {
                                    Task { await run(data, passphrase: passphrase) }
                                }
                            }
                            .disabled(passphrase.isEmpty || busy)
                        }
                    }
                }
                .interactiveDismissDisabled(busy)
            }
    }

    private func run(_ data: Data, passphrase: String?) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await model.importAgeIdentities(data, passphrase: passphrase)
            pending = nil
            onResult(ageImportMessage(result))
        } catch AgeIdentityStore.ImportError.wrongPassphrase {
            // Keep the prompt open for another try; nothing was written.
            dialogError = AgeIdentityStore.ImportError.wrongPassphrase.ponyMessage
        } catch {
            pending = nil
            onResult(error.ponyMessage)
        }
    }
}

func ageImportMessage(_ r: AgeIdentityStore.ImportResult) -> String {
    if r.added == 0 { return L("PassPony already has every identity in that file.") }
    if r.alreadyPresent == 0 { return L("Added \(r.added) age identities.") }
    return L("Added \(r.added) age identities; \(r.alreadyPresent) already here.")
}

extension View {
    func ageIdentitiesImporter(isPresented: Binding<Bool>, onResult: @escaping (String) -> Void) -> some View {
        modifier(AgeIdentitiesImporter(isPresented: isPresented, onResult: onResult))
    }
}
