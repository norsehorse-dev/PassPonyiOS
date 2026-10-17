import SwiftUI

struct EntryDetailView: View {
    @EnvironmentObject var model: AppModel
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var content: Data?
    @State private var revealed = false
    @State private var error: String?
    @State private var showingEdit = false
    /// Whether the edit sheet opens straight into the one-time code setup
    /// (the "Set up one-time code" shortcut). A flag, never a secret.
    @State private var editOpensOtp = false
    @State private var showingMove = false
    /// The last HOTP code shown; kept until the screen goes.
    @State private var hotpCode: String?
    @State private var hotpError: String?
    /// The passkey waiting on the delete confirmation: its public ids only.
    @State private var deletingPasskey: PasskeyRef?
    @State private var passkeyError: String?

    private struct PasskeyRef {
        let credentialId: Data
        let rpId: String
    }

    var body: some View {
        List {
            if let content {
                if entryIsOtpOnly(content: content) {
                    // Line 1 is the URI (`pass otp insert`): there is no
                    // password to show, and 1.0 showed the URI as one.
                    otpSection(content, caption: "This entry is a one-time code only.")
                    fieldsSection(content)
                    passkeysSection(content)
                } else {
                    passwordSection(content)
                    fieldsSection(content)
                    if hasTotp(content) {
                        otpSection(content, caption: nil)
                    }
                    passkeysSection(content)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(name.components(separatedBy: "/").last ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editOpensOtp = false
                        showingEdit = true
                    } label: {
                        Label("Edit fields", systemImage: "pencil")
                    }
                    .disabled(content == nil)
                    if let content, !hasTotp(content) {
                        Button {
                            editOpensOtp = true
                            showingEdit = true
                        } label: {
                            Label("Set up one-time code", systemImage: "timer")
                        }
                    }
                    Button {
                        showingMove = true
                    } label: {
                        Label("Move / rename", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEdit, onDismiss: { editOpensOtp = false }) {
            if let content {
                EditEntryView(
                    name: name,
                    original: content,
                    openOtpSetup: editOpensOtp,
                    onSave: { load() },
                    // The entry is gone; this detail view is stale. Pop it.
                    onDeleted: { dismiss() }
                )
            }
        }
        .sheet(isPresented: $showingMove) {
            MoveEntryView(currentName: name) {
                // Name changed; this detail view is stale. Pop it.
                dismiss()
            }
        }
        .alert(
            "Delete this passkey?",
            isPresented: Binding(
                get: { deletingPasskey != nil },
                set: { if !$0 { deletingPasskey = nil } }
            ),
            presenting: deletingPasskey
        ) { passkey in
            Button("Delete passkey", role: .destructive) { removePasskey(passkey) }
            Button("Cancel", role: .cancel) {}
        } message: { passkey in
            Text("You won't be able to sign in to \(passkey.rpId) with it anymore. Remove it from your account on the site too.")
        }
        .task { load() }
        .onDisappear {
            content = nil // no lingering plaintext
            deletingPasskey = nil
        }
    }

    private func load() {
        do {
            content = try model.readEntry(name)
        } catch {
            self.error = error.ponyMessage
        }
    }

    /// Whether the entry carries an `otpauth://` line, TOTP or (2.0) HOTP.
    /// Cheap: a parse of already-decrypted bytes, no re-decryption.
    private func hasTotp(_ content: Data) -> Bool {
        entryOtpKind(content: content) != nil
    }

    @ViewBuilder
    private func otpSection(_ content: Data, caption: LocalizedStringKey?) -> some View {
        if entryOtpKind(content: content) == .hotp {
            hotpSection(content, caption: caption)
        } else {
            totpSection(content, caption: caption)
        }
    }

    /// Counter-based code: nothing is shown until asked. "Show next code"
    /// advances the counter, saves and commits the entry, then shows the
    /// code, the same as `pass otp code`.
    @ViewBuilder
    private func hotpSection(_ content: Data, caption: LocalizedStringKey?) -> some View {
        Section {
            if let line = entryOtpSummaryLine(content: content) {
                Text(verbatim: line).font(.footnote).foregroundStyle(.secondary)
            }
            if let hotpCode {
                HStack {
                    Text(verbatim: groupedCode(hotpCode))
                        .font(.system(.title2, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        Clipboard.copyEphemeral(Data(hotpCode.utf8))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Show next code") {
                do {
                    let advance = try model.advanceHotp(name: name, content: content)
                    self.content = advance.content
                    hotpCode = advance.code
                    hotpError = nil
                } catch {
                    hotpError = error.ponyMessage
                }
            }
            if let hotpError {
                Text(hotpError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("One-time code")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Each code uses up one counter value and is saved to the entry, the same as pass otp code.")
                if let caption { Text(caption) }
            }
        }
    }

    private func groupedCode(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<mid]) \(code[mid...])"
    }

    @ViewBuilder
    private func passwordSection(_ content: Data) -> some View {
        let password = entryPassword(content: content)
        Section("Password") {
            HStack {
                Text(
                    revealed
                        ? (String(data: password, encoding: .utf8) ?? "•binary•")
                        : String(repeating: "•", count: max(8, password.count))
                )
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                Spacer()
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                Button {
                    Clipboard.copyEphemeral(password)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// 2.0 rc3: each passkey as one line, site and account, with delete.
    /// The passkey itself is never shown or copied.
    @ViewBuilder
    private func passkeysSection(_ content: Data) -> some View {
        let passkeys = entryPasskeys(content: content)
        if !passkeys.isEmpty {
            Section {
                ForEach(passkeys, id: \.credentialId) { passkey in
                    HStack {
                        Image(systemName: "person.badge.key")
                            .foregroundStyle(.secondary)
                        if passkey.username.isEmpty {
                            Text("Passkey for \(passkey.rpId)")
                        } else {
                            Text("Passkey for \(passkey.rpId), \(passkey.username)")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            deletingPasskey = PasskeyRef(credentialId: passkey.credentialId, rpId: passkey.rpId)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete passkey")
                    }
                }
                if let passkeyError {
                    Text(passkeyError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Passkeys")
            }
        }
    }

    private func removePasskey(_ passkey: PasskeyRef) {
        guard let content else { return }
        do {
            self.content = try model.removePasskey(name: name, content: content, credentialId: passkey.credentialId)
            passkeyError = nil
        } catch {
            passkeyError = error.ponyMessage
        }
    }

    @ViewBuilder
    private func fieldsSection(_ content: Data) -> some View {
        // Passkey lines have their own section; their value is a key.
        let fields = entryFields(content: content).filter { $0.key != "passkey" }
        if !fields.isEmpty {
            Section("Fields") {
                ForEach(fields, id: \.key) { field in
                    HStack {
                        Text(field.key).foregroundStyle(.secondary)
                        Spacer()
                        Text(field.value)
                            .textSelection(.enabled)
                        Button {
                            Clipboard.copyEphemeral(Data(field.value.utf8))
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func totpSection(_ content: Data, caption: LocalizedStringKey?) -> some View {
        Section {
            TOTPRingView(content: content)
        } header: {
            Text("One-time code")
        } footer: {
            if let caption {
                Text(caption)
            }
        }
    }
}
