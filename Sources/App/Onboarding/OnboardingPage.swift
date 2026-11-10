import SwiftUI
import AgePonyCore
import AuthenticationServices
import LocalAuthentication
import UniformTypeIdentifiers

/// Renders a single onboarding slide: icon, title, body, plus the slide's
/// interactive element. The import and try-pass slides act on the REAL
/// store (clone via GitSync, key files into PGPKeyStore, first entry via
/// AddEntryView), and on replay they collapse to a checkmark indicator so
/// nothing destructive is offered twice.
struct OnboardingPage: View {
    let slide: OnboardingSlide
    let onAdvance: () -> Void

    @EnvironmentObject var model: AppModel

    @State private var format = StorePaths.currentFormat
    @State private var showCloneSheet = false
    @State private var importingKeys = false
    @State private var importingAgeIdentities = false
    @State private var restoringBackup = false
    @State private var showAddSheet = false
    @State private var entryCountBeforeAdd = 0
    @State private var autofillEnabled = false
    @State private var status: String?
    @State private var recoveryRecipient = ""
    @State private var keyReady = EnclaveAgeIdentity.isEnabled || AgeIdentityStore.hasIdentities

    var body: some View {
        // Center-or-scroll (the PGPony fix for tall language lists): the
        // content centers exactly when it fits and scrolls when it doesn't.
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 28) {
                    Spacer(minLength: 8)

                    Image(systemName: slide.action == .biometric ? biometricIcon : slide.icon)
                        .font(.system(size: 56))
                        .foregroundStyle(slide.iconTint)
                        .accessibilityHidden(true)

                    Text(slide.title)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)

                    Text(slide.body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    actionArea

                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
        }
        .sheet(isPresented: $showCloneSheet) {
            OnboardingCloneSheet {
                status = L("Store cloned.")
                onAdvance()
            }
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            if model.entries.count > entryCountBeforeAdd {
                status = L("Saved. That's your first pass.")
                onAdvance()
            }
        }) {
            AddEntryView()
        }
        .fileImporter(
            isPresented: $importingKeys,
            allowedContentTypes: [.data, .text],
            allowsMultipleSelection: true
        ) { result in
            importKeys(result)
        }
    }

    // MARK: - Per-slide action area

    @ViewBuilder
    private var actionArea: some View {
        switch slide.action {
        case .none, .biometric:
            EmptyView()
        case .languagePicker:
            languagePicker
        case .formatPicker:
            formatPicker
        case .ageKey:
            ageKeyArea
        case .importStore:
            importArea
        case .tryPass:
            tryArea
        case .autofill:
            autofillArea
        }
    }

    // MARK: - Language

    private var languagePicker: some View {
        VStack(spacing: 0) {
            languageRow(code: "", label: Text("System"))
            Divider().padding(.leading, 16)
            languageRow(code: "en", label: Text(verbatim: "English"))
            Divider().padding(.leading, 16)
            languageRow(code: "es", label: Text(verbatim: "Español"))
            Divider().padding(.leading, 16)
            languageRow(code: "fr", label: Text(verbatim: "Français"))
            Divider().padding(.leading, 16)
            languageRow(code: "de", label: Text(verbatim: "Deutsch"))
            Divider().padding(.leading, 16)
            languageRow(code: "zh-Hans", label: Text(verbatim: "简体中文"))
            Divider().padding(.leading, 16)
            languageRow(code: "pt-BR", label: Text(verbatim: "Português (Brasil)"))
            Divider().padding(.leading, 16)
            languageRow(code: "ru", label: Text(verbatim: "Русский"))
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func languageRow(code: String, label: Text) -> some View {
        Button {
            model.language = code
        } label: {
            HStack {
                label.foregroundStyle(.primary)
                Spacer()
                if model.language == code {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Format

    private var formatPicker: some View {
        Picker("Store format", selection: $format) {
            Text("passage (age)").tag(StoreFormat.passage)
            Text("pass (OpenPGP)").tag(StoreFormat.pass)
        }
        .pickerStyle(.menu)
        .onChange(of: format) { _, newValue in
            StorePaths.currentFormat = newValue
            model.openStore()
        }
    }

    // MARK: - Device identity and optional off-device recovery

    @ViewBuilder
    private var ageKeyArea: some View {
        if model.format != .passage {
            Text("OpenPGP keys are set up on the next screen.").font(.footnote)
        } else {
            VStack(spacing: 12) {
                if EnclaveAgeIdentity.isEnabled {
                    Label("Secure Enclave key ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        do {
                            let previousKeys = DeviceKeys.ownKeys()
                            _ = try EnclaveAgeIdentity.create()
                            if let store = model.store {
                                let existing = (try store.rootRecipients()) ?? ""
                                let recipients = recipientsAdd(existing: existing, keys: previousKeys + DeviceKeys.ownKeys())
                                if recipients.changed > 0 {
                                    try store.setRootRecipients(text: recipients.text)
                                    try? model.git?.commitPaths(paths: [DeviceKeys.recipientsFile], message: commitMessageRecipientsAdd())
                                }
                            }
                            keyReady = true
                            status = L("Secure Enclave key created.")
                        } catch { status = error.localizedDescription }
                    } label: {
                        Label("Use Secure Enclave", systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if !AgeIdentityStore.hasIdentities {
                        Button("Use a software key instead") {
                            do {
                                try AgeIdentityStore.createSoftwareIdentity()
                                keyReady = true
                                status = L("Software key created. Back it up separately.")
                            } catch { status = error.localizedDescription }
                        }.buttonStyle(.bordered)
                    } else {
                        Text("Your existing software key stays available for older entries.").font(.footnote)
                    }
                }
                if keyReady {
                    TextField("Optional recovery public key (age1…)", text: $recoveryRecipient)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Add recovery public key") { addRecoveryRecipient() }
                        .disabled(recoveryRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Only the public recipient is stored here. Keep its private key elsewhere.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func addRecoveryRecipient() {
        do {
            let key = recoveryRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
            if TagRecipient.isTagRecipient(key) { _ = try TagRecipient(ageRecipient: key) }
            else { _ = try X25519Recipient(ageRecipient: key) }
            guard let store = model.store else { throw StoreError.NoStore }
            let existing = (try store.rootRecipients()) ?? ""
            let edit = recipientsAdd(existing: existing, keys: DeviceKeys.ownKeys() + [key])
            if edit.changed > 0 {
                try store.setRootRecipients(text: edit.text)
                try? model.git?.commitPaths(paths: [DeviceKeys.recipientsFile], message: commitMessageRecipientsAdd())
            }
            recoveryRecipient = ""
            status = L("Recovery public key added.")
        } catch {
            status = L("Could not add that recovery public key. Check it and try again.")
        }
    }

    // MARK: - Import

    @ViewBuilder
    private var importArea: some View {
        VStack(spacing: 12) {
            // A clone populates entries; the key step stays reachable after
            // it, since a cloned store is exactly when the key is needed.
            if model.entries.isEmpty {
                Button {
                    showCloneSheet = true
                } label: {
                    Label("Clone existing store…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                existingIndicator
            }
            if model.format == .passage {
                Button {
                    importingAgeIdentities = true
                } label: {
                    Label("Import identities file…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .ageIdentitiesImporter(isPresented: $importingAgeIdentities) { result in
                    status = result
                }
            } else {
                Button {
                    importingKeys = true
                } label: {
                    Label("Import key file…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            // A PassPony backup carries keys for both formats.
            Button {
                restoringBackup = true
            } label: {
                Label("Restore from backup…", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .backupRestorer(isPresented: $restoringBackup) { result in
                status = result
            }
        }
    }

    private func importKeys(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        PGPKeyStore.ensureDirectory()
        var imported = 0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let dest = PGPKeyStore.keyDirectory.appendingPathComponent(url.lastPathComponent)
            if let data = try? Data(contentsOf: url) {
                try? data.write(to: dest, options: [.completeFileProtection])
                imported += 1
            }
        }
        if imported > 0 {
            // OpenPGP key files imply a pass store; align the format so the
            // rest of the tour (and the store) matches what was imported.
            StorePaths.currentFormat = .pass
            format = .pass
            model.openStore()
            status = L("Imported \(imported) key files.")
        }
    }

    // MARK: - Try a pass

    @ViewBuilder
    private var tryArea: some View {
        if model.entries.isEmpty {
            Button {
                entryCountBeforeAdd = model.entries.count
                showAddSheet = true
            } label: {
                Label("Add a pass…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.format == .passage && !EnclaveAgeIdentity.isEnabled && !AgeIdentityStore.hasIdentities)
        } else {
            existingIndicator
        }
    }

    private var existingIndicator: some View {
        Label("You already have \(model.entries.count) passes", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }

    // MARK: - Autofill

    /// In-app enable prompt (iOS 18 API): no Settings round trip, and no
    /// race against the provider registration that made the raw Settings
    /// deep link land on a list without PassPony during first run.
    @ViewBuilder
    private var autofillArea: some View {
        VStack(spacing: 12) {
            if autofillEnabled {
                Label("Autofill is on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    ASSettingsHelper.requestToTurnOnCredentialProviderExtension { enabled in
                        DispatchQueue.main.async {
                            autofillEnabled = enabled
                            if enabled {
                                // Enabled just now: earlier syncs were
                                // skipped while the provider was off, so
                                // push the identity index immediately.
                                AutofillIdentities.sync(entries: model.entries)
                            }
                        }
                    }
                } label: {
                    Label("Turn on autofill", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    ASSettingsHelper.openCredentialProviderAppSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
        }
        .task {
            ASCredentialIdentityStore.shared.getState { state in
                DispatchQueue.main.async {
                    autofillEnabled = state.isEnabled
                }
            }
        }
    }

    // MARK: - Biometric icon

    private var biometricIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return slide.icon
        }
    }
}
