// Passkeys in the credential provider extension (2.0 rc3).
//
// The key pair is made with CryptoKit (P-256, ES256) and handed to the core
// as PKCS#8, which builds the WebAuthn bytes and the `passkey:` line. The
// line goes into an entry in the store, encrypted like everything else,
// with one commit. Signing in reads the entry back, signs
// `authenticatorData || clientDataHash`, and drops the key.
//
// The unlock gate is the user verification: within the grace window a
// passkey is used at once, otherwise the system auth sheet comes first.

import AuthenticationServices
import CryptoKit
import SwiftUI

enum PasskeyVault {
    private static var fileExtension: String {
        StorePaths.currentFormat == .passage ? "age" : "gpg"
    }

    /// The entry a new passkey goes in: one that already holds a passkey
    /// for the site, else an entry named after the site, else the site.
    static func suggestedEntry(rpId: String) -> String {
        let format = StorePaths.currentFormat
        if let known = PasskeyIndex.forRpId(rpId, format: format).first {
            return known.entryName
        }
        let names = ((try? PassStore.open(root: StorePaths.storeRoot.path, format: format))
            .flatMap { try? $0.entries() } ?? [])
            .filter { !$0.hidden }
            .map(\.name)
        return names.first { $0 == rpId || $0.hasSuffix("/\(rpId)") } ?? rpId
    }

    /// Make the key, add the passkey to `entryName` (creating the entry when
    /// it does not exist yet), commit, index, and register the identity.
    static func register(
        entryName: String,
        rpId: String,
        userHandle: Data,
        userName: String,
        clientDataHash: Data
    ) throws -> ASPasskeyRegistrationCredential {
        let format = StorePaths.currentFormat
        let root = StorePaths.storeRoot.path
        let store = try PassStore.open(root: root, format: format)
        let backend = EngineProvider.engine(for: format)

        let key = P256.Signing.PrivateKey()
        var pkcs8 = key.derRepresentation
        defer { pkcs8.resetBytes(in: 0..<pkcs8.count) }
        let point = key.publicKey.rawRepresentation
        let registration = try passkeyRegister(
            rpId: rpId,
            userHandle: userHandle,
            username: userName,
            userDisplayName: userName,
            keyPkcs8: pkcs8,
            x: Data(point.prefix(32)),
            y: Data(point.suffix(32)),
            userVerified: true
        )

        var existing = store.hasEntry(name: entryName)
            ? try store.readEntry(name: entryName, backend: backend)
            : Data()
        defer { existing.resetBytes(in: 0..<existing.count) }
        var content = entryAddPasskey(content: existing, value: registration.value)
        defer { content.resetBytes(in: 0..<content.count) }
        try store.writeEntry(name: entryName, content: content, backend: backend)
        if let git = try? GitSync.open(root: root) {
            try? git.commitPaths(
                paths: ["\(entryName).\(fileExtension)"],
                message: commitMessagePasskeyAdd(name: entryName)
            )
        }
        PasskeyIndex.updateEntry(entryName, content: content, format: format)
        ASCredentialIdentityStore.shared.saveCredentialIdentities([
            ASPasskeyCredentialIdentity(
                relyingPartyIdentifier: rpId,
                userName: entryName,
                credentialID: registration.credentialId,
                userHandle: userHandle,
                recordIdentifier: entryName
            ),
        ])

        return ASPasskeyRegistrationCredential(
            relyingParty: rpId,
            clientDataHash: clientDataHash,
            credentialID: registration.credentialId,
            attestationObject: registration.attestationObject
        )
    }

    /// Sign in with the passkey `credentialId` for `rpId` stored in
    /// `entryName`. The entry and the key are wiped from memory after.
    static func assertion(
        entryName: String,
        rpId: String,
        credentialId: Data,
        clientDataHash: Data
    ) throws -> ASPasskeyAssertionCredential {
        let format = StorePaths.currentFormat
        let store = try PassStore.open(root: StorePaths.storeRoot.path, format: format)
        var content = try store.readEntry(name: entryName, backend: EngineProvider.engine(for: format))
        defer { content.resetBytes(in: 0..<content.count) }
        guard let passkey = entryPasskeys(content: content)
            .first(where: { $0.credentialId == credentialId && $0.rpId == rpId })
        else {
            throw ASExtensionError(.credentialIdentityNotFound)
        }
        let assertion = try passkeyAssert(value: passkey.value, userVerified: true)
        var pkcs8 = assertion.keyPkcs8
        defer { pkcs8.resetBytes(in: 0..<pkcs8.count) }
        let key = try P256.Signing.PrivateKey(derRepresentation: pkcs8)
        let message = passkeySignedMessage(
            authenticatorData: assertion.authenticatorData,
            clientDataHash: clientDataHash
        )
        let signature = try key.signature(for: message).derRepresentation
        return ASPasskeyAssertionCredential(
            userHandle: assertion.userHandle,
            relyingParty: rpId,
            signature: signature,
            clientDataHash: clientDataHash,
            authenticatorData: assertion.authenticatorData,
            credentialID: assertion.credentialId
        )
    }

    /// The entry holding a passkey iOS picked from its sheet: the record
    /// identifier we registered, else a lookup in the index.
    static func entryName(for identity: ASPasskeyCredentialIdentity) -> String? {
        if let name = identity.recordIdentifier, !name.isEmpty { return name }
        return PasskeyIndex.forRpId(identity.relyingPartyIdentifier, format: StorePaths.currentFormat)
            .first { $0.credentialId == identity.credentialID }?
            .entryName
    }
}

/// "Save passkey": which entry the new passkey goes in.
struct PasskeyRegistrationView: View {
    let rpId: String
    let userName: String
    let onSave: @MainActor (_ entryName: String) async -> String?
    let onCancel: () -> Void

    @State private var entryName: String
    @State private var busy = false
    @State private var error: String?

    init(
        rpId: String,
        userName: String,
        suggested: String,
        onSave: @escaping @MainActor (_ entryName: String) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.rpId = rpId
        self.userName = userName
        self.onSave = onSave
        self.onCancel = onCancel
        _entryName = State(initialValue: suggested)
    }

    private var cleanName: String {
        entryName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Site", value: rpId)
                    if !userName.isEmpty {
                        LabeledContent("Account", value: userName)
                    }
                }
                Section {
                    TextField("Entry", text: $entryName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(busy)
                } header: {
                    Text("Entry")
                } footer: {
                    Text("The passkey is added to this entry. If it doesn't exist yet, PassPony creates it.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save passkey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        busy = true
                        error = nil
                        Task {
                            error = await onSave(cleanName)
                            busy = false
                        }
                    }
                    .disabled(busy || cleanName.isEmpty)
                }
            }
        }
        .environment(\.locale, AppLanguage.locale)
    }
}

/// The passkeys PassPony holds for a site, when iOS asks us to list them.
struct PasskeyPickerView: View {
    let rpId: String
    let refs: [PasskeyIndex.Ref]
    let onPick: @MainActor (PasskeyIndex.Ref) async -> String?
    let onCancel: () -> Void

    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(refs, id: \.credentialId) { ref in
                        Button {
                            busy = true
                            error = nil
                            Task {
                                error = await onPick(ref)
                                busy = false
                            }
                        } label: {
                            Label(ref.entryName, systemImage: "person.badge.key")
                        }
                        .disabled(busy)
                    }
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if refs.isEmpty {
                    ContentUnavailableView(
                        "No passkeys",
                        systemImage: "person.badge.key",
                        description: Text("PassPony has no passkey for \(rpId).")
                    )
                }
            }
            .navigationTitle(rpId)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(busy)
                }
            }
        }
        .environment(\.locale, AppLanguage.locale)
    }
}
