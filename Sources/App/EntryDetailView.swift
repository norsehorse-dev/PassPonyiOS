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

    var body: some View {
        List {
            if let content {
                if entryIsOtpOnly(content: content) {
                    // Line 1 is the URI (`pass otp insert`): there is no
                    // password to show, and 1.0 showed the URI as one.
                    totpSection(content, caption: "This entry is a one-time code only.")
                    fieldsSection(content)
                } else {
                    passwordSection(content)
                    fieldsSection(content)
                    if hasTotp(content) {
                        totpSection(content, caption: nil)
                    }
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
        .task { load() }
        .onDisappear { content = nil } // no lingering plaintext
    }

    private func load() {
        do {
            content = try model.readEntry(name)
        } catch {
            self.error = error.ponyMessage
        }
    }

    /// Whether the entry carries a parsable `otpauth://totp/` line. Cheap:
    /// a parse of already-decrypted bytes, no re-decryption.
    private func hasTotp(_ content: Data) -> Bool {
        entryTotpSummary(content: content) != nil
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

    @ViewBuilder
    private func fieldsSection(_ content: Data) -> some View {
        let fields = entryFields(content: content)
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
