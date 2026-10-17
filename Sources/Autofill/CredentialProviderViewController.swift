import AuthenticationServices
import SwiftUI
import os

private let log = Logger(
    subsystem: "dev.norsehorse.passpony.autofill",
    category: "provider"
)

/// The autofill extension. P3/P4 flow per the spike memo
/// (PassPonyCore docs/spike-corenfc-credential-extension.md):
/// - without-UI path serves from the app-group store when possible,
///   else throws userInteractionRequired;
/// - with-UI path shows the entry picker (and, in week one, the spike checks).
final class CredentialProviderViewController: ASCredentialProviderViewController {

    // MARK: Without UI — the 95% path.
    //
    // Works today because the identities file carries no passphrase gate yet.
    // When the unlock policy lands (biometric gate / cached passphrase per
    // the spike memo), this path first checks cache validity and escalates
    // with userInteractionRequired on a miss.

    /// The shared fill: resolve the identity, open the store, decrypt.
    /// Both request paths use this and map failures to the error code
    /// appropriate for their context.
    private func credential(
        for credentialRequest: ASCredentialRequest
    ) -> Result<ASPasswordCredential, Error> {
        guard
            let identity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity,
            let name = identity.recordIdentifier
        else {
            return .failure(ASExtensionError(.credentialIdentityNotFound))
        }
        do {
            let format = StorePaths.currentFormat
            let store = try PassStore.open(
                root: StorePaths.storeRoot.path,
                format: format
            )
            let content = try store.readEntry(
                name: name,
                backend: EngineProvider.engine(for: format)
            )
            let password = String(
                data: entryPassword(content: content), encoding: .utf8
            ) ?? ""
            let username = entryFields(content: content)
                .first { $0.key == "username" || $0.key == "login" }?
                .value ?? ""
            return .success(ASPasswordCredential(user: username, password: password))
        } catch {
            return .failure(error)
        }
    }

    override func provideCredentialWithoutUserInteraction(
        for credentialRequest: ASCredentialRequest
    ) {
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            guard UnlockGate.isFresh else { return cancel(.userInteractionRequired) }
            switch passkeyAssertion(for: passkeyRequest) {
            case .success(let credential):
                extensionContext.completeAssertionRequest(using: credential)
            case .failure(let error):
                log.error("no-UI passkey failed: \(String(describing: error), privacy: .public)")
                cancel(.userInteractionRequired)
            }
            return
        }
        guard UnlockGate.isFresh else {
            log.info("no-UI fill: unlock window lapsed, escalating to UI")
            return cancel(.userInteractionRequired)
        }
        switch credential(for: credentialRequest) {
        case .success(let credential):
            extensionContext.completeRequest(withSelectedCredential: credential)
        case .failure(let error):
            log.error("no-UI fill failed: \(String(describing: error), privacy: .public) store=\(StorePaths.storeRoot.path, privacy: .public)")
            cancel(.userInteractionRequired)
        }
    }

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: code.rawValue
        ))
    }

    // MARK: With UI, single credential — the grace window lapsed. iOS
    // re-invokes us here after userInteractionRequired; run the system auth
    // sheet, then serve the same fill. Failures here must NOT cancel with
    // userInteractionRequired (we ARE the interactive path; iOS just
    // dismisses and nothing fills) — they end the request as failed.

    override func prepareInterfaceToProvideCredential(
        for credentialRequest: ASCredentialRequest
    ) {
        AppLanguage.activate()
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            Task { @MainActor in
                guard await UnlockGate.authenticate(reason: L("Unlock PassPony to use your passkey")) else {
                    return self.cancel(.userCanceled)
                }
                switch self.passkeyAssertion(for: passkeyRequest) {
                case .success(let credential):
                    self.extensionContext.completeAssertionRequest(using: credential)
                case .failure(let error):
                    log.error("UI passkey failed: \(String(describing: error), privacy: .public)")
                    self.cancel(.failed)
                }
            }
            return
        }
        Task { @MainActor in
            guard await UnlockGate.authenticate(reason: L("Unlock to fill your password")) else {
                log.info("UI fill: authentication declined")
                return self.cancel(.userCanceled)
            }
            switch self.credential(for: credentialRequest) {
            case .success(let credential):
                self.extensionContext.completeRequest(withSelectedCredential: credential)
            case .failure(let error):
                log.error("UI fill failed: \(String(describing: error), privacy: .public) store=\(StorePaths.storeRoot.path, privacy: .public)")
                self.cancel(.failed)
            }
        }
    }

    // MARK: With UI

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier]
    ) {
        // The extension is a separate process; adopt the app's language
        // override before building the picker UI.
        AppLanguage.activate()
        let host = UIHostingController(
            rootView: AutofillPickerView(
                serviceHint: serviceIdentifiers.first?.identifier ?? "",
                onPick: { [weak self] password, username in
                    self?.extensionContext.completeRequest(
                        withSelectedCredential: ASPasswordCredential(
                            user: username,
                            password: password
                        )
                    )
                },
                onCancel: { [weak self] in
                    self?.extensionContext.cancelRequest(withError: NSError(
                        domain: ASExtensionErrorDomain,
                        code: ASExtensionError.userCanceled.rawValue
                    ))
                }
            )
        )
        embed(host)
    }

    private func embed(_ host: UIViewController) {
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }

    // MARK: Passkeys (2.0 rc3)

    private func passkeyAssertion(
        for request: ASPasskeyCredentialRequest
    ) -> Result<ASPasskeyAssertionCredential, Error> {
        guard
            let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
            let entryName = PasskeyVault.entryName(for: identity)
        else {
            return .failure(ASExtensionError(.credentialIdentityNotFound))
        }
        return Result {
            try PasskeyVault.assertion(
                entryName: entryName,
                rpId: identity.relyingPartyIdentifier,
                credentialId: identity.credentialID,
                clientDataHash: request.clientDataHash
            )
        }
    }

    /// The site asked to create a passkey and the person chose PassPony.
    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        AppLanguage.activate()
        guard
            let request = registrationRequest as? ASPasskeyCredentialRequest,
            let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        else {
            return cancel(.failed)
        }
        guard request.supportedAlgorithms.contains(.ES256) else {
            log.info("passkey registration: site offers no ES256")
            return cancel(.failed)
        }
        let rpId = identity.relyingPartyIdentifier
        // WebAuthn: a credential the site already lists means "already
        // registered"; the site shows its own message for that.
        let known = PasskeyIndex.forRpId(rpId, format: StorePaths.currentFormat)
        if let excluded = request.excludedCredentials,
           excluded.contains(where: { ex in known.contains { $0.credentialId == ex.credentialID } }) {
            return cancel(.matchedExcludedCredential)
        }
        let clientDataHash = request.clientDataHash
        let userHandle = identity.userHandle
        let userName = identity.userName
        embed(UIHostingController(rootView: PasskeyRegistrationView(
            rpId: rpId,
            userName: userName,
            suggested: PasskeyVault.suggestedEntry(rpId: rpId),
            onSave: { [weak self] entryName in
                if !UnlockGate.isFresh {
                    guard await UnlockGate.authenticate(reason: L("Unlock PassPony to use your passkey")) else {
                        return L("PassPony needs to be unlocked to save the passkey.")
                    }
                }
                do {
                    let credential = try PasskeyVault.register(
                        entryName: entryName,
                        rpId: rpId,
                        userHandle: userHandle,
                        userName: userName,
                        clientDataHash: clientDataHash
                    )
                    self?.extensionContext.completeRegistrationRequest(using: credential)
                    return nil
                } catch {
                    log.error("passkey registration failed: \(String(describing: error), privacy: .public)")
                    return error.ponyMessage
                }
            },
            onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )))
    }

    /// iOS asks for PassPony's passkeys for a site (the person chose
    /// PassPony rather than one of the suggested passkeys).
    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        AppLanguage.activate()
        let rpId = requestParameters.relyingPartyIdentifier
        let allowed = requestParameters.allowedCredentials
        let refs = PasskeyIndex.forRpId(rpId, format: StorePaths.currentFormat)
            .filter { allowed.isEmpty || allowed.contains($0.credentialId) }
        let clientDataHash = requestParameters.clientDataHash
        embed(UIHostingController(rootView: PasskeyPickerView(
            rpId: rpId,
            refs: refs,
            onPick: { [weak self] ref in
                guard await UnlockGate.authenticate(reason: L("Unlock PassPony to use your passkey")) else {
                    return L("PassPony needs to be unlocked to use the passkey.")
                }
                do {
                    let credential = try PasskeyVault.assertion(
                        entryName: ref.entryName,
                        rpId: rpId,
                        credentialId: ref.credentialId,
                        clientDataHash: clientDataHash
                    )
                    self?.extensionContext.completeAssertionRequest(using: credential)
                    return nil
                } catch {
                    log.error("passkey sign-in failed: \(String(describing: error), privacy: .public)")
                    return error.ponyMessage
                }
            },
            onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )))
    }
}

struct AutofillPickerView: View {
    let serviceHint: String
    let onPick: (_ password: String, _ username: String) -> Void
    let onCancel: () -> Void

    @State private var entries: [EntryRef] = []
    @State private var search = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(filtered, id: \.name) { entry in
                Button {
                    pick(entry.name)
                } label: {
                    Text(entry.name)
                }
            }
            .searchable(text: $search)
            .navigationTitle("Choose entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                #if DEBUG
                // Dev-only capability spike; never ships in release builds.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Spike") { SpikeChecksView() }
                }
                #endif
            }
            .task { load() }
            .overlay {
                if let error {
                    ContentUnavailableView(
                        "Store unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                }
            }
        }
        // Follow the app's in-app language override (app-group defaults).
        .environment(\.locale, AppLanguage.locale)
    }

    private var filtered: [EntryRef] {
        let visible = entries.filter { !$0.hidden }
        // Rank service-matching entries first, then the rest.
        let needle = search.isEmpty ? serviceHint : search
        guard !needle.isEmpty else { return visible }
        let lowered = needle.lowercased()
        let hits = visible.filter { $0.name.lowercased().contains(lowered) }
        return search.isEmpty ? hits + visible.filter { !hits.contains($0) } : hits
    }

    private func load() {
        do {
            let store = try PassStore.open(
                root: StorePaths.storeRoot.path,
                format: StorePaths.currentFormat
            )
            entries = try store.entries()
        } catch {
            self.error = error.ponyMessage
        }
    }

    private func pick(_ name: String) {
        do {
            let format = StorePaths.currentFormat
            let store = try PassStore.open(
                root: StorePaths.storeRoot.path,
                format: format
            )
            let content = try store.readEntry(
                name: name,
                backend: EngineProvider.engine(for: format)
            )
            let password = String(
                data: entryPassword(content: content), encoding: .utf8
            ) ?? ""
            let username = entryFields(content: content)
                .first { $0.key == "username" || $0.key == "login" }?
                .value ?? ""
            onPick(password, username)
        } catch {
            self.error = error.ponyMessage
        }
    }
}
