// QuickType registration: mirror the entry-name index into iOS's credential
// identity store so suggestions appear above the keyboard. Names only —
// nothing here decrypts anything (plan §7: autofill from the name index).

import AuthenticationServices

enum AutofillIdentities {
    /// Replace the registered identities with the current entry index.
    /// Call after any change to the store (open, save, delete, sync).
    static func sync(entries: [EntryRef]) {
        let store = ASCredentialIdentityStore.shared
        store.getState { state in
            guard state.isEnabled else { return } // user hasn't enabled us yet
            let identities: [ASCredentialIdentity] = entries
                .filter { !$0.hidden }
                .map { entry in
                    ASPasswordCredentialIdentity(
                        serviceIdentifier: ASCredentialServiceIdentifier(
                            identifier: serviceHint(for: entry.name),
                            type: .domain
                        ),
                        user: entry.name,
                        recordIdentifier: entry.name
                    )
                }
            store.replaceCredentialIdentities(identities)
        }
    }

    /// Best domain guess from the entry name: the deepest path component
    /// containing a dot wins (`web/github.com` → `github.com`); otherwise
    /// the leaf name. The long tail of site-matching heuristics lives here
    /// eventually; the copy-fallback picker always works regardless.
    static func serviceHint(for name: String) -> String {
        let parts = name.split(separator: "/").map(String.init)
        return parts.reversed().first(where: { $0.contains(".") }) ?? parts.last ?? name
    }
}
