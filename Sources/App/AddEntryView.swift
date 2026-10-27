import SwiftUI

/// A brand-new entry: password line, then an optional `username: ...`
/// line, then an optional `url: ...` line, each only when non-empty, then
/// (since 1.1) the optional `otpauth://` line last, the position
/// `pass otp append` gives it. With no password and a code, the URI is
/// the first line instead, which is exactly the entry `pass otp insert`
/// creates. Same assembly as Android's `NewEntryContent`.
struct AddEntryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var username = ""
    @State private var url = ""
    /// The one-time code chosen in the setup sheet, held here until Save.
    @State private var otpauth: String?
    @State private var showingOtpSetup = false
    @State private var showingGenerator = false
    /// Why the last Save failed (no .gpg-id yet, no usable key, ...).
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                Section("Entry") {
                    TextField("Name (e.g. web/github)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
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
                        .accessibilityIdentifier("generatorSettingsButton")
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
                Section("One-time code (optional)") {
                    if let otpauth {
                        if let summary = otpSummaryLine(uri: otpauth) {
                            Text(summary)
                        }
                        HStack {
                            Button("Change…") { showingOtpSetup = true }
                            Spacer()
                            Button("Remove", role: .destructive) { self.otpauth = nil }
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button("Add one-time code…") { showingOtpSetup = true }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("addCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || (password.isEmpty && otpauth == nil))
                }
            }
            .sheet(isPresented: $showingOtpSetup) {
                TOTPSetupSheet { uri in
                    otpauth = uri
                }
            }
            .sheet(isPresented: $showingGenerator) {
                GeneratorSheet { generated in
                    password = generated
                }
            }
        }
    }

    private func save() {
        let otpOnly = password.isEmpty && otpauth != nil
        var content = (otpOnly ? otpauth ?? "" : password) + "\n"
        if !username.isEmpty { content += "username: \(username)\n" }
        if !url.isEmpty { content += "url: \(url)\n" }
        if !otpOnly, let otpauth { content += otpauth + "\n" }
        if model.saveEntry(name: name, content: Data(content.utf8), isNew: true) {
            dismiss()
        } else {
            saveError = model.lastError
        }
    }
}
