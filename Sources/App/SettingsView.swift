import SwiftUI
import UniformTypeIdentifiers

/// Store settings: format switch (the plan's open decision, now a user
/// choice), OpenPGP key import for pass stores, and the way in to the
/// Diagnostics screen.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("passpony.onboardingCompleted") private var onboardingCompleted = true

    @State private var format = StorePaths.currentFormat
    @State private var keyFiles: [String] = []
    @State private var importing = false
    @State private var initializing = false
    @State private var reencrypting = false
    @State private var keyPassphrase = ""
    @State private var lockedKeys: [String] = []
    @State private var gpgIDLines: [String] = []
    @State private var message: String?
    @State private var importingAge = false
    @State private var ageHints: [String] = []
    @State private var agePresent = false
    @State private var enclaveRecipient: String?
    @State private var confirmingEnclave = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Store format", selection: $format) {
                        Text("passage (age)").tag(StoreFormat.passage)
                        Text("pass (OpenPGP)").tag(StoreFormat.pass)
                    }
                    .onChange(of: format) { _, newValue in
                        StorePaths.currentFormat = newValue
                        model.openStore()
                    }
                } footer: {
                    Text("Each format keeps its own store. Switching never touches the other store's data.")
                }

                if format == .pass {
                    Section("OpenPGP keys") {
                        if keyFiles.isEmpty {
                            Text("No keys imported. A pass store needs at least a public key matching its .gpg-id (and the secret key to decrypt).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(keyFiles, id: \.self) { name in
                            Label(name, systemImage: "key")
                        }
                        .onDelete(perform: deleteKeys)
                        Button {
                            importing = true
                        } label: {
                            Label("Import key file…", systemImage: "square.and.arrow.down")
                        }
                    }

                    if !lockedKeys.isEmpty {
                        Section {
                            ForEach(lockedKeys, id: \.self) { file in
                                Label(file, systemImage: "lock")
                                    .foregroundStyle(.orange)
                            }
                            SecureField("Key passphrase", text: $keyPassphrase)
                            Button("Unlock") { unlockKeys() }
                                .disabled(keyPassphrase.isEmpty)
                        } header: {
                            Text("Locked keys")
                        } footer: {
                            Text("The passphrase is cached for \(Int(UnlockGate.gracePeriod / 60)) minutes (shared with autofill), then cleared.")
                        }
                    }

                    Section {
                        if gpgIDLines.isEmpty {
                            Button {
                                initializing = true
                            } label: {
                                Label("Initialize store with key…", systemImage: "key")
                            }
                            .disabled(keyFiles.isEmpty)
                        } else {
                            ForEach(gpgIDLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospaced())
                            }
                        }
                    } header: {
                        Text("Store recipients (.gpg-id)")
                    } footer: {
                        Text(gpgIDLines.isEmpty
                             ? "A pass store encrypts to the keys listed in its .gpg-id. Initialize once with your imported keys."
                             : "To change the keys of a store in use, use Re-encrypt store.")
                    }
                }

                if format == .passage {
                    Section {
                        if let enclaveRecipient {
                            Text("Secure Enclave identity is active on this device.")
                            Text(verbatim: enclaveRecipient).font(.caption.monospaced()).textSelection(.enabled)
                            ShareLink(item: enclaveRecipient) { Label("Share public recipient", systemImage: "square.and.arrow.up") }
                        } else if EnclaveAgeIdentity.isEnabled {
                            Text("The Secure Enclave identity could not be loaded. Restore access to this device's key before continuing.")
                        } else {
                            Button("Create Secure Enclave identity…") { confirmingEnclave = true }
                        }
                    } header: {
                        Text("Device-bound age key")
                    } footer: {
                        Text("This key cannot be backed up or transferred. Keep a separate recovery recipient. Existing software keys remain usable until you safely re-encrypt older entries.")
                    }
                    .confirmationDialog("Create a device-bound age key?", isPresented: $confirmingEnclave, titleVisibility: .visible) {
                        Button("Create key") {
                            do {
                                let previousKeys = DeviceKeys.ownKeys()
                                enclaveRecipient = try EnclaveAgeIdentity.create()
                                if let store = model.store {
                                    let existing = (try store.rootRecipients()) ?? ""
                                    let edit = recipientsAdd(existing: existing, keys: previousKeys + DeviceKeys.ownKeys())
                                    if edit.changed > 0 {
                                        try store.setRootRecipients(text: edit.text)
                                        try? model.git?.commitPaths(paths: [DeviceKeys.recipientsFile], message: commitMessageRecipientsAdd())
                                    }
                                }
                            } catch {
                                message = error.localizedDescription
                            }
                        }
                    } message: {
                        Text("The new key becomes the active age identity. Existing software identities remain on this device and may still decrypt entries addressed to them. Review the store recipients and retain a separate recovery key.")
                    }
                    Section {
                        (agePresent
                            ? Text("Identities file present.")
                            : Text("No identities imported. A passage store needs the age identity it was encrypted to."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(ageHints, id: \.self) { hint in
                            Text(verbatim: hint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            importingAge = true
                        } label: {
                            Label("Import identities file…", systemImage: "square.and.arrow.down")
                        }
                        .ageIdentitiesImporter(isPresented: $importingAge) { result in
                            message = result
                            refreshKeys()
                        }
                    } header: {
                        Text("Age identities")
                    }
                }

                Section {
                    NavigationLink {
                        BackupView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Back up and restore keys")
                                Text("Encrypted backup, plain export, restore")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "externaldrive")
                        }
                    }
                } header: {
                    Text("Backup")
                }

                Section {
                    NavigationLink {
                        SshKeyView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SSH key and trusted hosts")
                                Text("For ssh:// and git@host: remotes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.horizontal")
                        }
                    }
                } header: {
                    Text("SSH")
                }

                Section("Maintenance") {
                    Button {
                        reencrypting = true
                    } label: {
                        Label("Re-encrypt store…", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                }

                // Live in-app override, applied immediately: Text picks it
                // up via the root locale environment (RootView), formatted
                // strings via L(_:). Language names stay in their own
                // language on purpose (verbatim, not localized).
                Section {
                    Picker(selection: $model.language) {
                        Text("System").tag("")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Español").tag("es")
                        Text(verbatim: "Français").tag("fr")
                        Text(verbatim: "Deutsch").tag("de")
                        Text(verbatim: "简体中文").tag("zh-Hans")
                        Text(verbatim: "Português (Brasil)").tag("pt-BR")
                        Text(verbatim: "Русский").tag("ru")
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                    // Replay the first-run tour. Closing the sheet first
                    // lets RootView swap straight to the carousel; the
                    // interactive slides adapt when the store already has
                    // entries or keys.
                    Button {
                        model.showingSettings = false
                        onboardingCompleted = false
                    } label: {
                        Label("Show welcome tour again", systemImage: "book")
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    Link(destination: URL(string: Self.appRepoURL)!) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("PassPony on GitHub")
                                    .foregroundStyle(.primary)
                                Text("The full app source (Apache-2.0).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    Link(destination: URL(string: Self.coreRepoURL)!) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Crypto core on GitHub")
                                    .foregroundStyle(.primary)
                                Text("Open source (Apache-2.0). Inspect the cryptography.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    Link(destination: URL(string: "mailto:norsehorse@norsehor.se")!) {
                        Label("Contact", systemImage: "envelope")
                    }
                } header: {
                    Text("About")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Diagnostics")
                                Text("Version, store, and sync details for a support message. No secrets.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "stethoscope")
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    ForEach(Self.otherApps.indices, id: \.self) { index in
                        let app = Self.otherApps[index]
                        Link(destination: URL(string: app.url)!) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .foregroundStyle(.primary)
                                    Text(app.tagline)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: app.icon)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                } header: {
                    Text("More from NorseHorse")
                } footer: {
                    Text("Other apps from the same developer.")
                }

                if let message {
                    Section { Text(message).font(.footnote) }
                }
            }
            // Re-key the form in place on language change: the sheet stays
            // presented, only its content rebuilds in the new language.
            .id(model.language)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.data, .text],
                allowsMultipleSelection: true
            ) { result in
                importKeys(result)
            }
            .sheet(isPresented: $initializing, onDismiss: { refreshKeys() }) {
                InitializeStoreView()
            }
            .sheet(isPresented: $reencrypting) {
                ReencryptView()
            }
            .onAppear { refreshKeys() }
        }
    }

    // MARK: - About / other apps

    private static let appRepoURL = "https://github.com/norsehorse-dev/PassPonyiOS"
    private static let coreRepoURL = "https://github.com/norsehorse-dev/PassPonyCore"

    /// App names render verbatim (brand names, never translated); taglines
    /// are LocalizedStringKey and resolve through the catalog.
    /// One treatment for every row: the app's symbol in the accent color.
    private static let otherApps: [(name: String, tagline: LocalizedStringKey, icon: String, url: String)] = [
        ("PGPony", "OpenPGP messages, files, and keys", "envelope.fill",
         "https://apps.apple.com/us/app/pgpony/id6759994432"),
        ("AgePony", "File encryption with age", "lock.fill",
         "https://apps.apple.com/app/id6774821172"),
        ("QuorumPony", "Quorum key backup and recovery", "person.3.fill",
         "https://apps.apple.com/us/app/quorumpony-key-backup/id6783608628"),
        ("CarrierPony", "PGP chat and encrypted files", "paperplane.fill",
         "https://apps.apple.com/us/app/carrierpony-pgp-chat-files/id6786930072"),
        ("BurnPony", "Self-destructing encrypted messages", "flame.fill",
         "https://apps.apple.com/us/app/burnpony/id6788513233"),
        ("RelayPony", "Encrypted file transfer", "arrow.left.arrow.right",
         "https://apps.apple.com/us/app/relaypony-file-transfer/id6785085525"),
        // App Store id not available here; the product site, as Android links.
        ("VaultPony", "VeraCrypt-compatible encrypted vaults on your device", "lock.rectangle.stack.fill",
         "https://vaultpony.app"),
        ("ScrubPony", "Strip metadata from photos", "photo",
         "https://apps.apple.com/us/app/scrubpony-strip-metadata/id6803265054"),
        ("TapPony", "Webhooks from NFC tags", "wave.3.right",
         "https://apps.apple.com/us/app/tappony-webhook-automation/id6817057965"),
    ]

    /// Marketing version from the bundle so the displayed version tracks
    /// the real build instead of a hardcoded value.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func refreshKeys() {
        PGPKeyStore.ensureDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: PGPKeyStore.keyDirectory, includingPropertiesForKeys: nil
        )) ?? []
        keyFiles = files.map(\.lastPathComponent).sorted()
        let gpgID = StorePaths.storeRoot(for: .pass).appendingPathComponent(".gpg-id")
        gpgIDLines = (try? String(contentsOf: gpgID, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        // Building the engine is what discovers locked keys — opening the
        // store alone never decrypts, so we must actually load here.
        if format == .pass {
            _ = try? PGPonyEngine(
                keyDirectory: PGPKeyStore.keyDirectory,
                passphrase: PassphraseCache.load()
            )
        }
        lockedKeys = PGPKeyStore.lockedKeyFiles
        agePresent = AgeIdentityStore.hasIdentities
        ageHints = AgeIdentityStore.publicKeyHints()
        enclaveRecipient = EnclaveAgeIdentity.isEnabled ? try? EnclaveAgeIdentity.load().recipient.toBech32() : nil
    }

    private func unlockKeys() {
        let attempt = keyPassphrase
        keyPassphrase = ""
        // Load the engine directly with the candidate passphrase, then
        // inspect what's still locked — that's the pass/fail signal.
        _ = try? PGPonyEngine(
            keyDirectory: PGPKeyStore.keyDirectory,
            passphrase: attempt
        )
        let stillLocked = PGPKeyStore.lockedKeyFiles
        if stillLocked.isEmpty {
            PassphraseCache.save(attempt)
            message = L("Key unlocked.")
            model.openStore()
        } else if stillLocked.contains(where: { $0.contains("wrong passphrase") }) {
            message = L("Wrong passphrase.")
        } else {
            // Some keys unlocked, others need a different passphrase.
            PassphraseCache.save(attempt)
            message = L("Unlocked some keys; \(stillLocked.count) still locked.")
            model.openStore()
        }
        lockedKeys = stillLocked
        refreshKeys()
    }

    private func importKeys(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        PGPKeyStore.ensureDirectory()
        var imported = 0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let dest = PGPKeyStore.keyDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                let data = try Data(contentsOf: url)
                try data.write(to: dest, options: [.completeFileProtection])
                imported += 1
            } catch {
                message = L("Couldn't import \(url.lastPathComponent).")
            }
        }
        if imported > 0 {
            message = L("Imported \(imported) key files.")
        }
        refreshKeys()
        model.openStore()
    }

    private func deleteKeys(at offsets: IndexSet) {
        for index in offsets {
            let url = PGPKeyStore.keyDirectory.appendingPathComponent(keyFiles[index])
            try? FileManager.default.removeItem(at: url)
        }
        refreshKeys()
        model.openStore()
    }
}
