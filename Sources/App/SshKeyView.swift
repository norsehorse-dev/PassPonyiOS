import SwiftUI
import UniformTypeIdentifiers

/// SSH key and trusted hosts (2.0 rc2), reached from Settings and Sync.
///
/// One key per app: generate an Ed25519 key or import an OpenSSH private
/// key (a passphrase-protected one is decrypted once, here, and then kept
/// in this device's Keychain). The public key is shown to copy into a git
/// host. Delete asks first, since a host that only knows this key stops
/// accepting the app. Trusted hosts lists what was pinned on first
/// connection; forgetting one makes the next connection ask again.
struct SshKeyView: View {
    @State private var key: SshKey?
    @State private var hosts: [KnownHost] = []
    @State private var message: String?
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var importing = false
    @State private var pendingImport: Data?
    @State private var passphrase = ""
    @State private var passphraseError: String?

    var body: some View {
        Form {
            if let key {
                Section {
                    Text(verbatim: key.publicKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text(verbatim: "\(key.algorithm) · \(key.fingerprint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        // Not a secret, but it still clears itself like every copy.
                        Clipboard.copyEphemeral(Data(key.publicKey.utf8))
                        message = L("Public key copied.")
                    } label: {
                        Label("Copy public key", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Public key")
                } footer: {
                    Text("Add this to your git host, for example in GitHub's SSH keys settings or a server's authorized_keys file.")
                }
                Section {
                    Button("Delete SSH key", role: .destructive) { confirmDelete = true }
                        .disabled(busy)
                }
            } else {
                Section {
                    Text("No SSH key yet. Generate one here, or import an OpenSSH private key, to sync with ssh:// and git@host: remotes.")
                    Button("Generate SSH key") { generate() }
                        .disabled(busy)
                    Button("Import SSH key…") { importing = true }
                        .disabled(busy)
                }
            }

            if let message {
                Section { Text(message).font(.footnote) }
            }

            Section {
                if hosts.isEmpty {
                    Text("None yet. The first time PassPony connects to an SSH host, it shows the host's fingerprint and asks.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(hosts, id: \.host) { host in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: host.host)
                        Text(verbatim: "\(host.key.keyType) · \(host.key.fingerprint)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) { forget(host.host) }
                    }
                    .contextMenu {
                        Button("Forget", role: .destructive) { forget(host.host) }
                    }
                }
            } header: {
                Text("Trusted hosts")
            }
        }
        .navigationTitle("SSH key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .confirmationDialog("Delete this SSH key?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete SSH key", role: .destructive) {
                SshKeyStore.delete()
                message = L("SSH key deleted.")
                refresh()
            }
        } message: {
            Text("Git hosts that only know this key will stop accepting this app. A backup made after the key was set up still has a copy.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                message = SshKeyError.NotAKey.ponyMessage
                return
            }
            if sshKeyIsEncrypted(data: data) {
                passphrase = ""
                passphraseError = nil
                pendingImport = data
            } else {
                importKey(data, passphrase: nil)
            }
        }
        .sheet(isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                            .disabled(busy)
                    } footer: {
                        Text("This SSH key is protected with a passphrase. Enter it to import the key. PassPony then keeps the key protected by this device instead.")
                    }
                    if let passphraseError {
                        Section { Text(passphraseError).foregroundStyle(.red).font(.footnote) }
                    }
                    if busy {
                        Section { ProgressView() }
                    }
                }
                .navigationTitle("SSH key passphrase")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { pendingImport = nil }.disabled(busy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            if let data = pendingImport { importKey(data, passphrase: passphrase) }
                        }
                        .disabled(passphrase.isEmpty || busy)
                    }
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func refresh() {
        key = SshKeyStore.load()
        hosts = SshKeyStore.trustedHosts
    }

    private func generate() {
        busy = true
        Task.detached {
            let result: String
            do {
                try SshKeyStore.generate()
                result = L("SSH key generated. Add the public key to your git host.")
            } catch {
                result = error.ponyMessage
            }
            await MainActor.run {
                message = result
                busy = false
                refresh()
            }
        }
    }

    private func importKey(_ data: Data, passphrase: String?) {
        busy = true
        passphraseError = nil
        Task.detached {
            do {
                try SshKeyStore.importKey(data, passphrase: passphrase)
                await MainActor.run {
                    pendingImport = nil
                    message = L("SSH key imported.")
                    busy = false
                    refresh()
                }
            } catch SshKeyError.WrongPassphrase {
                await MainActor.run {
                    passphraseError = L("Wrong passphrase for this SSH key.")
                    busy = false
                }
            } catch {
                await MainActor.run {
                    pendingImport = nil
                    message = error.ponyMessage
                    busy = false
                }
            }
        }
    }

    private func forget(_ host: String) {
        do {
            try SshKeyStore.forget(host: host)
            message = L("Forgot \(host). The next connection asks again.")
        } catch {
            message = error.ponyMessage
        }
        refresh()
    }
}
