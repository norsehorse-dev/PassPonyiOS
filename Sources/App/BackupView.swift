import SwiftUI
import UniformTypeIdentifiers

/// Keys backup (2.0): an encrypted `.passpony` backup of every key on this
/// device, locked with a generated recovery code the user types back before
/// saving; a plain export of the age identities file behind a warning; and
/// restore. The code and the key material live only in this view's state.
struct BackupView: View {
    @EnvironmentObject var model: AppModel

    private enum Step: Equatable {
        case idle
        case showCode(String)
        case confirm(String)
    }

    @State private var step: Step = .idle
    @State private var typed = ""
    @State private var confirmError: String?
    @State private var message: String?
    @State private var busy = false
    @State private var exportingBackup = false
    @State private var backupDocument: BackupFile?
    @State private var confirmingPlain = false
    @State private var exportingPlain = false
    @State private var plainDocument: BackupFile?
    @State private var restoring = false
    @State private var backedUp = KeyBackupState.backedUp

    private var hasAgeIdentities: Bool { AgeIdentityStore.hasIdentities }
    private var pgpKeyCount: Int {
        ((try? FileManager.default.contentsOfDirectory(
            at: PGPKeyStore.keyDirectory, includingPropertiesForKeys: nil
        )) ?? []).count
    }
    private var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    var body: some View {
        Form {
            Section {
                (backedUp ? Text("Your keys are backed up.") : Text("Your keys aren't backed up yet."))
                    .foregroundStyle(backedUp ? Color.secondary : Color.red)
            } footer: {
                Text("Sync copies your encrypted entries, not your keys. A new phone can clone your store but can't read it without a key backup.")
            }

            Section {
                switch step {
                case .idle:
                    Button("Create backup…") {
                        message = nil
                        do {
                            step = .showCode(try backupGenerateRecoveryCode())
                        } catch {
                            message = error.ponyMessage
                        }
                    }
                    .disabled(!hasAgeIdentities && pgpKeyCount == 0 && !SshKeyStore.hasKey)
                    .accessibilityIdentifier("createBackupButton")
                case .showCode(let code):
                    Text("This is your recovery code. Write it down and keep it somewhere safe.")
                    HStack {
                        Text(verbatim: code)
                            .font(.title3.monospaced())
                            .textSelection(.disabled)
                        Spacer()
                        Button {
                            Clipboard.copyEphemeral(Data(code.utf8))
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy"))
                    }
                    Text("The backup can't be opened without this code, and PassPony can't show it again after this.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("I've written it down") {
                        typed = ""
                        confirmError = nil
                        step = .confirm(code)
                    }
                    Button("Cancel", role: .cancel) { step = .idle }
                case .confirm(let code):
                    Text("Type the recovery code from what you wrote down.")
                    TextField("Recovery code", text: $typed)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if let confirmError {
                        Text(confirmError).foregroundStyle(.red).font(.footnote)
                    }
                    Button("Save backup…") { save(code: code) }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    Button("Show the code again") { step = .showCode(code) }
                    if busy { ProgressView() }
                }
            } header: {
                Text("Encrypted backup")
            } footer: {
                Text("Your age identities, any imported PGP keys and the SSH key, in one .passpony file locked with a recovery code. Keep the file wherever you like. Without the code it can't be opened.")
            }

            if hasAgeIdentities {
                Section {
                    Button("Export identities file…") { confirmingPlain = true }
                } header: {
                    Text("Plain export")
                } footer: {
                    Text("Your age identities file as plain text, the same file the passage and age tools read.")
                }
            }

            Section {
                Button("Restore from backup…") { restoring = true }
                    .backupRestorer(isPresented: $restoring) { result in
                        message = result
                        backedUp = KeyBackupState.backedUp
                    }
            } header: {
                Text("Restore")
            } footer: {
                Text("Restore keys from a .passpony backup. They are added to the keys already here; nothing is replaced.")
            }

            if let message {
                Section { Text(message).font(.footnote) }
            }
        }
        .navigationTitle("Keys backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $exportingBackup,
            document: backupDocument,
            contentType: .data,
            defaultFilename: "passpony-backup-\(today).passpony"
        ) { result in
            switch result {
            case .success:
                model.markKeysBackedUp()
                backedUp = true
                step = .idle
                message = L("Backup saved.")
            case .failure:
                message = L("Couldn't save the backup file.")
            }
            backupDocument = nil
        }
        .alert("Export your key unencrypted?", isPresented: $confirmingPlain) {
            Button("Export", role: .destructive) {
                if let text = AgeIdentityStore.exportText() {
                    plainDocument = BackupFile(data: Data(text.utf8))
                    exportingPlain = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone who gets this file can read your passage entries. Keep it somewhere only you can reach, or use the encrypted backup instead.")
        }
        .background(
            Color.clear.fileExporter(
                isPresented: $exportingPlain,
                document: plainDocument,
                contentType: .plainText,
                defaultFilename: "passpony-age-identities.txt"
            ) { result in
                if case .success = result {
                    model.markKeysBackedUp()
                    backedUp = true
                    message = L("Identities file saved.")
                }
                plainDocument = nil
            }
        )
    }

    private func save(code: String) {
        let normalized: String
        do {
            normalized = try backupNormalizeRecoveryCode(input: typed)
        } catch {
            confirmError = error.ponyMessage
            return
        }
        guard normalized == code else {
            confirmError = L("That's a valid code, but not this one. Check what you wrote down.")
            return
        }
        confirmError = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                backupDocument = BackupFile(data: try await model.buildBackup(recoveryCode: code))
                exportingBackup = true
            } catch {
                message = L("Couldn't save: \(error.ponyMessage)")
            }
        }
    }
}

/// The bytes handed to `fileExporter`: a `.passpony` backup or a plain
/// identities file. Lives only until the export finishes.
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .plainText] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
