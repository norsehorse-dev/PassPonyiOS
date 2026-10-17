import SwiftUI

/// An SSH host to confirm, and the action to run again once it is trusted.
struct HostPrompt: Identifiable {
    let id = UUID()
    let host: String
    let key: HostKey
    let retry: () async throws -> Void
}

/// Trust on first use for an SSH host (2.0 rc2): shown when a clone, sync
/// or push stops with `GitError.UnknownHostKey`. The fingerprint is the
/// `SHA256:` form git hosts publish, so the user can compare it before
/// saying yes. Trusting pins the key and the caller retries; a different
/// key for the same host later is refused outright, with no prompt.
struct HostKeyTrustModifier: ViewModifier {
    @Binding var prompt: HostPrompt?
    var onTrust: (HostPrompt) -> Void
    var onCancel: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Trust this host?",
            isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
            presenting: prompt
        ) { shown in
            Button("Trust and connect") {
                prompt = nil
                onTrust(shown)
            }
            Button("Cancel", role: .cancel) {
                prompt = nil
                onCancel()
            }
        } message: { shown in
            Text(verbatim: [
                L("This is the first connection to \(shown.host). Its key fingerprint is:"),
                shown.key.fingerprint + "\n" + shown.key.keyType,
                L("Compare it with the fingerprint your git host publishes before you trust it."),
            ].joined(separator: "\n\n"))
        }
    }
}

extension View {
    func hostKeyTrust(
        _ prompt: Binding<HostPrompt?>,
        onTrust: @escaping (HostPrompt) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(HostKeyTrustModifier(prompt: prompt, onTrust: onTrust, onCancel: onCancel))
    }
}
