import SwiftUI

struct EntryDetailView: View {
    @EnvironmentObject var model: AppModel
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var content: Data?
    @State private var revealed = false
    @State private var error: String?
    @State private var showingEdit = false
    @State private var showingMove = false

    var body: some View {
        List {
            if let content {
                passwordSection(content)
                fieldsSection(content)
                totpSection(content)
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
                        showingEdit = true
                    } label: {
                        Label("Edit fields", systemImage: "pencil")
                    }
                    .disabled(content == nil)
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
        .sheet(isPresented: $showingEdit) {
            if let content {
                EditEntryView(name: name, original: content) {
                    load()
                }
            }
        }
        .sheet(isPresented: $showingMove) {
            MoveEntryView(currentName: name) {
                // Name changed; this detail view is stale — pop it.
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
    private func totpSection(_ content: Data) -> some View {
        if entryTotp(content: content, unixTime: UInt64(Date().timeIntervalSince1970)) != nil {
            Section("One-time code") {
                TOTPRingView(content: content)
            }
        }
    }
}
