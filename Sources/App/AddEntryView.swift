import SwiftUI

struct AddEntryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var username = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    TextField("Name (e.g. web/github)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Password") {
                    HStack {
                        SecureField("Password", text: $password)
                        Button("Generate") {
                            password = Self.generate()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Section("Fields (optional)") {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("url", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle("New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func save() {
        var content = password + "\n"
        if !username.isEmpty { content += "username: \(username)\n" }
        if !url.isEmpty { content += "url: \(url)\n" }
        model.saveEntry(name: name, content: Data(content.utf8), isNew: true)
        dismiss()
    }

    /// Charset generator matching pass defaults (25 chars, with symbols).
    /// Diceware and per-store defaults come later (plan §5).
    static func generate(length: Int = 25) -> String {
        let charset = Array(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        )
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            charset[Int(rng.next() % UInt64(charset.count))]
        })
    }
}
