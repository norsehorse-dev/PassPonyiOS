import AuthenticationServices
import SwiftUI

/// The autofill extension. P3/P4 flow per the spike memo
/// (PassPonyCore docs/spike-corenfc-credential-extension.md):
/// - without-UI path serves from the app-group store when possible,
///   else throws userInteractionRequired;
/// - with-UI path shows the entry picker (and, in week one, the spike checks).
final class CredentialProviderViewController: ASCredentialProviderViewController {

    // MARK: Without UI — the 95% path once passphrase caching lands (P4).

    override func provideCredentialWithoutUserInteraction(
        for credentialRequest: ASCredentialRequest
    ) {
        // Until the cached-vault-key flow lands, always escalate to UI.
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userInteractionRequired.rawValue
        ))
    }

    // MARK: With UI

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier]
    ) {
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
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
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
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Spike") { SpikeChecksView() }
                }
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
                format: .passage
            )
            entries = try store.entries()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func pick(_ name: String) {
        do {
            let store = try PassStore.open(
                root: StorePaths.storeRoot.path,
                format: .passage
            )
            let content = try store.readEntry(
                name: name,
                backend: EngineProvider.engine(for: .passage)
            )
            let password = String(
                data: entryPassword(content: content), encoding: .utf8
            ) ?? ""
            let username = entryFields(content: content)
                .first { $0.key == "username" || $0.key == "login" }?
                .value ?? ""
            onPick(password, username)
        } catch {
            self.error = String(describing: error)
        }
    }
}

extension EntryRef: Equatable {
    public static func == (lhs: EntryRef, rhs: EntryRef) -> Bool {
        lhs.name == rhs.name && lhs.hidden == rhs.hidden
    }
}
