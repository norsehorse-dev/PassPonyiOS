import SwiftUI

/// Rename or move an entry (a rename into another folder is a move: the
/// same operation, `pass mv` semantics via the core).
struct MoveEntryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let currentName: String
    var onMoved: () -> Void

    @State private var newName: String
    @State private var error: String?

    init(currentName: String, onMoved: @escaping () -> Void) {
        self.currentName = currentName
        self.onMoved = onMoved
        _newName = State(initialValue: currentName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New name") {
                    TextField("folder/name", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Move / rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        if model.moveEntry(from: currentName, to: newName) {
                            dismiss()
                            onMoved()
                        } else {
                            error = model.lastError
                        }
                    }
                    .disabled(newName.isEmpty || newName == currentName)
                }
            }
        }
    }
}

/// The user's decision about the entry's `otpauth://` line, made in the
/// setup sheet or with the section's buttons and applied only on Save.
/// The same three states as Android's `OtpauthEdit`.
enum OtpauthEdit: Equatable {
    /// Leave whatever the entry has alone.
    case unchanged
    /// Add a code, or replace the existing one, with this URI.
    case set(String)
    /// Drop the existing code. Never offered for an OTP-only entry, whose
    /// URI is its first line; the codec refuses that removal.
    case remove
}

/// Field-level editing over the byte-faithful core helpers: only the value
/// bytes of changed fields, the first line (if changed), and since 1.1 the
/// one `otpauth://` line are rewritten; unknown lines, ordering, spacing,
/// and trailing-newline style all survive untouched (the P1 round-trip
/// guarantee, now user-facing).
///
/// Removing a field is deliberately absent: the codec has no
/// delete-with-fidelity primitive for fields, only for the `otpauth://`
/// line. The URI the setup sheet produces is held here, in view state,
/// until Save; it never reaches navigation or persisted state.
struct EditEntryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let name: String
    let original: Data
    var onSave: () -> Void
    /// The OTP-only case: the codec refuses to remove a URI that is the
    /// entry's first line, so this sheet offers to delete the entry
    /// instead, and the caller pops its now-stale detail view.
    var onDeleted: () -> Void

    @State private var password: String
    @State private var values: [String: String]
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var otpauthEdit: OtpauthEdit = .unchanged
    @State private var showingOtpSetup: Bool
    @State private var showingGenerator = false
    @State private var confirmingDelete = false

    private let fieldKeys: [String]
    private let originalValues: [String: String]
    private let originalPassword: String
    /// The entry's code as loaded (TOTP or HOTP), as its summary line; nil
    /// when it has none.
    private let originalTotp: String?
    /// Line 1 is the URI (what `pass otp insert` writes): no password to edit.
    private let otpOnly: Bool

    /// `openOtpSetup` opens the setup sheet on arrival (the detail screen's
    /// "Set up one-time code" shortcut); it is a flag, not a secret.
    init(
        name: String,
        original: Data,
        openOtpSetup: Bool = false,
        onSave: @escaping () -> Void,
        onDeleted: @escaping () -> Void = {}
    ) {
        self.name = name
        self.original = original
        self.onSave = onSave
        self.onDeleted = onDeleted
        let fields = entryFields(content: original)
        // First occurrence wins, matching the codec's set-field semantics.
        let pairs = Dictionary(
            fields.map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        // Passkey lines are shown and deleted on the detail screen, never
        // edited as text: one changed byte would break the passkey.
        self.fieldKeys = fields.map(\.key).filter { $0 != "passkey" && seen.insert($0).inserted }
        self.originalValues = pairs
        let pw = String(data: entryPassword(content: original), encoding: .utf8) ?? ""
        self.originalPassword = pw
        self.originalTotp = entryOtpKind(content: original) == nil
            ? nil
            : (entryOtpSummaryLine(content: original) ?? "")
        self.otpOnly = entryIsOtpOnly(content: original)
        _password = State(initialValue: pw)
        _values = State(initialValue: pairs)
        _showingOtpSetup = State(initialValue: openOtpSetup)
    }

    var body: some View {
        NavigationStack {
            Form {
                if otpOnly {
                    // Line 1 is the URI, so there is no password to edit;
                    // the code section below owns that line.
                    Section {
                        Text("This entry is a one-time code only.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Password") {
                        HStack {
                            SecureField("Password", text: $password)
                            Button("Generate") {
                                password = PasswordGenerator.generate()
                            }
                            .buttonStyle(.borderless)
                            Button {
                                showingGenerator = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Generator settings")
                        }
                    }
                }
                if !fieldKeys.isEmpty {
                    Section("Fields") {
                        ForEach(fieldKeys, id: \.self) { key in
                            TextField(
                                key,
                                text: Binding(
                                    get: { values[key] ?? "" },
                                    set: { values[key] = $0 }
                                )
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                    }
                }
                otpauthSection
                Section("Add field") {
                    TextField("key", text: $newKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("value", text: $newValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Edit \(name.components(separatedBy: "/").last ?? name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hasChanges)
                }
            }
            .sheet(isPresented: $showingOtpSetup) {
                TOTPSetupSheet { uri in
                    otpauthEdit = .set(uri)
                }
            }
            .sheet(isPresented: $showingGenerator) {
                GeneratorSheet { generated in
                    password = generated
                }
            }
            .confirmationDialog(
                "Delete entry?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    model.deleteEntry(name)
                    dismiss()
                    onDeleted()
                }
            } message: {
                Text("This deletes \"\(name)\" from the store. This can't be undone.")
            }
        }
    }

    /// The one-time code section's five states: no code, a pending new
    /// code, an existing code, a pending replacement, and a pending
    /// removal. Each shows the summary that applies and the actions that
    /// make sense from there; nothing is written until Save.
    @ViewBuilder
    private var otpauthSection: some View {
        Section("One-time code") {
            switch otpauthEdit {
            case .set(let uri):
                if let pending = otpSummaryLine(uri: uri) {
                    Text(pending)
                }
                if originalTotp == nil {
                    Text("Added when you save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Replaces the current code when you save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Change…") { showingOtpSetup = true }
                    Spacer()
                    if originalTotp == nil {
                        Button("Remove") { otpauthEdit = .unchanged }
                    } else {
                        Button("Keep current code") { otpauthEdit = .unchanged }
                    }
                }
                .buttonStyle(.borderless)
            case .remove:
                Text("Removed when you save.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Undo") { otpauthEdit = .unchanged }
                    .buttonStyle(.borderless)
            case .unchanged:
                if let originalTotp {
                    if !originalTotp.isEmpty {
                        Text(originalTotp)
                    }
                    HStack {
                        Button("Replace…") { showingOtpSetup = true }
                        Spacer()
                        if otpOnly {
                            Button("Delete entry", role: .destructive) { confirmingDelete = true }
                        } else {
                            Button("Remove", role: .destructive) { otpauthEdit = .remove }
                        }
                    }
                    .buttonStyle(.borderless)
                    if otpOnly {
                        Text("A code-only entry keeps its code. To get rid of it, delete the entry.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No one-time code")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Add one-time code…") { showingOtpSetup = true }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// Setting a URI always counts. Removing counts only when there is a
    /// code to remove: the codec's remove is a no-op on an entry without
    /// one, so Save must not light up for it.
    private var otpauthChanged: Bool {
        switch otpauthEdit {
        case .unchanged: return false
        case .set: return true
        case .remove: return originalTotp != nil
        }
    }

    private var hasChanges: Bool {
        password != originalPassword
            || fieldKeys.contains { values[$0] != originalValues[$0] }
            || (!newKey.isEmpty && !newValue.isEmpty)
            || otpauthChanged
    }

    /// Password first (if changed), then each changed existing field in
    /// the entry's own order, then a new field, then the one-time code
    /// last: the same sequence as Android's `EntryEditState.editSteps()`.
    /// Each step rewrites only its own slice of the bytes, so the order
    /// matters only for parity.
    private func save() {
        var content = original
        if password != originalPassword {
            content = entrySetPassword(content: content, password: Data(password.utf8))
        }
        for key in fieldKeys where values[key] != originalValues[key] {
            content = entrySetField(content: content, key: key, value: values[key] ?? "")
        }
        if !newKey.isEmpty && !newValue.isEmpty {
            content = entrySetField(
                content: content,
                key: newKey.trimmingCharacters(in: .whitespaces),
                value: newValue
            )
        }
        switch otpauthEdit {
        case .unchanged:
            break
        case .set(let uri):
            content = entrySetOtpauth(content: content, uri: uri)
        case .remove:
            if originalTotp != nil {
                content = entryRemoveOtpauth(content: content)
            }
        }
        model.saveEntry(name: name, content: content, isNew: false)
        onSave()
        dismiss()
    }
}
