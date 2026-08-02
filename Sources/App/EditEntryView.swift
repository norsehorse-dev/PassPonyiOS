import SwiftUI

/// Field-level editing over the byte-faithful core helpers: only the value
/// bytes of changed fields and (if changed) the first line are rewritten;
/// unknown lines, ordering, spacing, and trailing-newline style all survive
/// untouched (the P1 round-trip guarantee, now user-facing).
///
/// Removing a field is deliberately absent for now — the codec has no
/// delete-with-fidelity primitive yet; it lands with a core change, not an
/// app-side line filter.
struct EditEntryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let name: String
    let original: Data
    var onSave: () -> Void

    @State private var password: String
    @State private var values: [String: String]
    @State private var newKey = ""
    @State private var newValue = ""

    private let fieldKeys: [String]
    private let originalValues: [String: String]
    private let originalPassword: String

    init(name: String, original: Data, onSave: @escaping () -> Void) {
        self.name = name
        self.original = original
        self.onSave = onSave
        let fields = entryFields(content: original)
        // First occurrence wins, matching the codec's set-field semantics.
        let pairs = Dictionary(
            fields.map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        self.fieldKeys = fields.map(\.key).filter { seen.insert($0).inserted }
        self.originalValues = pairs
        let pw = String(data: entryPassword(content: original), encoding: .utf8) ?? ""
        self.originalPassword = pw
        _password = State(initialValue: pw)
        _values = State(initialValue: pairs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Password") {
                    HStack {
                        SecureField("Password", text: $password)
                        Button("Generate") {
                            password = AddEntryView.generate()
                        }
                        .buttonStyle(.borderless)
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
        }
    }

    private var hasChanges: Bool {
        password != originalPassword
            || fieldKeys.contains { values[$0] != originalValues[$0] }
            || (!newKey.isEmpty && !newValue.isEmpty)
    }

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
        model.saveEntry(name: name, content: content, isNew: false)
        onSave()
        dismiss()
    }
}
