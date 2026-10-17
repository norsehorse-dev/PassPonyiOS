import SwiftUI

/// Git sync UI: status, clone, sync, push. Conflict resolution presents the
/// per-file sheet from docs/conflict-ux.md (PassPonyCore) — one choice per
/// conflicted entry, never a silent merge.
struct SyncView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var cloneURL = ""
    @State private var publishURL = ""
    @State private var busy = false
    @State private var message: String?
    @State private var conflictPath: String?
    @State private var conflictContinuation: CheckedContinuation<ConflictChoice, Never>?
    @State private var hostPrompt: HostPrompt?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if model.git == nil {
                    publishSection
                    cloneSection
                } else {
                    actionsSection
                    if model.syncStatus?.hasRemote == false {
                        publishSection
                    } else {
                        remoteSection
                    }
                }
                if let message {
                    Section { Text(message).font(.footnote) }
                }
                // 2.0 rc2: SSH remotes use the app's key and pinned hosts.
                Section("SSH") {
                    NavigationLink("SSH key and trusted hosts") { SshKeyView() }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("syncDoneButton")
                }
            }
            .confirmationDialog(
                "Sync conflict: \(conflictPath ?? "")",
                isPresented: .init(
                    get: { conflictPath != nil },
                    set: { if !$0 { conflictPath = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Keep this device's version") { resolve(.keepLocal) }
                Button("Keep the other version") { resolve(.keepRemote) }
                Button("Keep both") { resolve(.keepBoth) }
            } message: {
                Text("This entry changed on this device and on another device.")
            }
            .hostKeyTrust($hostPrompt) { prompt in
                do {
                    try model.trustHost(prompt.host, key: prompt.key)
                } catch {
                    message = error.ponyMessage
                    return
                }
                run(prompt.retry)
            } onCancel: {
                message = L("Not connected. The host wasn't trusted.")
            }
            // 2.0 rc4: another device listed its key in .age-recipients.
            // Ask before re-encrypting anything to it, one key at a time.
            .alert(
                "New device key",
                isPresented: Binding(
                    get: { !busy && model.pendingDeviceKeys.first != nil },
                    set: { if !$0 && !busy { model.deferDeviceKeys() } }
                ),
                presenting: model.pendingDeviceKeys.first
            ) { key in
                Button("Re-encrypt") {
                    run {
                        let report = try await model.approveDeviceKey(key)
                        var text = L("Entries re-encrypted for the new key: \(report.rewritten.count).")
                        if report.skipped > 0 {
                            text += " " + L("Entries this device can't read, left for the device that saved them: \(Int(report.skipped)).")
                        }
                        await MainActor.run { message = text }
                    }
                }
                Button("Remove key", role: .destructive) {
                    run {
                        try await model.removeDeviceKey(key)
                        await MainActor.run {
                            message = L("Key removed. Nothing saved from now on will be encrypted to it.")
                        }
                    }
                }
                Button("Later", role: .cancel) { model.deferDeviceKeys() }
            } message: { key in
                Text(verbatim: [
                    L("Another device added this key to your store, so it can read what you save from now on:"),
                    key,
                    L("Check it against the key in PassPony's Settings on your other device. If it's yours, re-encrypt so that device can read your existing entries too. If you don't recognize it, remove it."),
                ].joined(separator: "\n\n"))
            }
        }
    }

    private var statusSection: some View {
        Section {
            if let st = model.syncStatus {
                LabeledContent("Unpushed", value: "\(st.ahead)")
                LabeledContent("Behind remote", value: "\(st.behind)")
                LabeledContent(
                    "Remote",
                    value: st.hasRemote
                        ? L("configured")
                        : L("none")
                )
            } else {
                Text("No git repository — clone a store or use local-only mode.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        } footer: {
            // 2.0: sync carries encrypted entries only.
            Text("Sync copies your encrypted entries, not your keys. A new phone can clone your store but can't read it without a key backup.")
        }
    }

    /// View and repoint the configured remote. The displayed URL redacts
    /// embedded credentials; entering a new URL (with fresh token) and
    /// tapping Update repoints origin.
    private var remoteSection: some View {
        Section {
            LabeledContent("Current") {
                Text(Self.redacted(model.git?.remoteUrl() ?? "—"))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("New URL (https://user:token@… or git@host:…)", text: $publishURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Update remote") {
                run {
                    try model.git?.setRemote(url: publishURL)
                    await MainActor.run {
                        message = L("Remote updated.")
                        publishURL = ""
                        model.refresh()
                    }
                }
            }
            .disabled(publishURL.isEmpty || busy)
        } header: {
            Text("Remote")
        }
    }

    /// Strip userinfo (user:token) from a URL for display.
    static func redacted(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://"),
              let at = url[schemeEnd.upperBound...].firstIndex(of: "@")
        else { return url }
        return url[..<schemeEnd.upperBound] + "•••@" + url[url.index(after: at)...]
    }

    /// Publish the current local store to an empty remote:
    /// init (commits everything, CLI-style messages) → set origin → push.
    private var publishSection: some View {
        Section {
            TextField("https://user:token@host/you/store.git or git@host:you/store.git", text: $publishURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Publish") {
                run {
                    let root = StorePaths.storeRoot.path
                    let git: GitSync
                    if let existing = model.git {
                        git = existing
                    } else {
                        git = try GitSync.`init`(root: root, format: model.format)
                    }
                    if let store = await MainActor.run(body: { model.store }) {
                        DeviceKeys.join(format: model.format, store: store, git: git)
                    }
                    try git.setRemote(url: publishURL)
                    git.setSsh(ssh: SshKeyStore.config())
                    try git.push()
                    await MainActor.run { model.openStore() }
                }
            }
            .disabled(publishURL.isEmpty || busy)
        } header: {
            Text("Publish this store")
        } footer: {
            Text("Commits the current store and pushes it to an empty remote. SSH remotes use the SSH key set up under SSH key and trusted hosts.")
        }
    }

    /// Replace the local store with a cloned one. Clones into a scratch
    /// directory first so a failed clone never harms the current store.
    private var cloneSection: some View {
        Section {
            TextField("https://user:token@host/you/store.git or git@host:you/store.git", text: $cloneURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Clone (replaces current store)", role: .destructive) {
                run {
                    let tmp = StorePaths.container.appendingPathComponent("clone-tmp")
                    try? FileManager.default.removeItem(at: tmp)
                    _ = try GitSync.cloneWithSsh(url: cloneURL, dest: tmp.path, depth: nil, ssh: SshKeyStore.config())
                    let root = StorePaths.storeRoot
                    try? FileManager.default.removeItem(at: root)
                    try FileManager.default.moveItem(at: tmp, to: root)
                    await MainActor.run { model.openStore() }
                    await model.joinAfterClone()
                }
            }
            .disabled(cloneURL.isEmpty || busy)
        } header: {
            Text("Clone existing store")
        } footer: {
            Text("The clone lands in a scratch area first — a failed clone leaves the current store untouched. On success it replaces the current store for this format. Decrypting cloned entries still needs the matching key: identities file for passage, imported OpenPGP key for pass.")
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button("Sync now") {
                run {
                    guard let git = model.git else { return }
                    let resolver = UIResolver { path in
                        await self.ask(path: path)
                    }
                    git.setSsh(ssh: SshKeyStore.config())
                    let outcome = try git.sync(resolver: resolver)
                    await MainActor.run {
                        self.message = Self.describe(outcome)
                        model.refresh()
                        if case .upToDate = outcome {} else { model.rebuildPasskeyIndex() }
                    }
                    await model.joinRecipients()
                }
            }
            .disabled(busy)
            Button("Push") {
                run {
                    guard let git = model.git else { throw GitError.NoRepository }
                    git.setSsh(ssh: SshKeyStore.config())
                    try git.push()
                    await MainActor.run { model.refresh() }
                }
            }
            .disabled(busy)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task.detached {
            do {
                try await work()
            } catch GitError.UnknownHostKey(let host, let key) {
                await MainActor.run { self.hostPrompt = HostPrompt(host: host, key: key, retry: work) }
            } catch {
                await MainActor.run { self.message = error.ponyMessage }
            }
            await MainActor.run { self.busy = false }
        }
    }

    @MainActor
    private func ask(path: String) async -> ConflictChoice {
        await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            conflictPath = path
        }
    }

    private func resolve(_ choice: ConflictChoice) {
        conflictPath = nil
        conflictContinuation?.resume(returning: choice)
        conflictContinuation = nil
    }

    static func describe(_ outcome: SyncOutcome) -> String {
        switch outcome {
        case .upToDate: return L("Already up to date.")
        case .fastForwarded: return L("Pulled changes from remote.")
        case .rebased(let replayed):
            return L("Merged cleanly (\(Int(replayed)) local changes replayed).")
        case .resolvedConflicts(let resolved, let keptBoth):
            var text = L("Resolved \(resolved.count) conflicts.")
            if !keptBoth.isEmpty {
                text += " " + L("Kept both for: \(keptBoth.joined(separator: ", ")).")
            }
            return text
        }
    }
}

/// Bridges the blocking FFI resolver callback to async SwiftUI presentation.
/// `choose` is called on the sync thread; it blocks on a semaphore while the
/// main actor presents the dialog and the user decides.
final class UIResolver: ConflictResolver, @unchecked Sendable {
    private let ask: @Sendable (String) async -> ConflictChoice

    init(ask: @escaping @Sendable (String) async -> ConflictChoice) {
        self.ask = ask
    }

    func choose(entryPath: String) -> ConflictChoice {
        let semaphore = DispatchSemaphore(value: 0)
        var choice = ConflictChoice.keepBoth // safe default is never reached
        Task {
            choice = await self.ask(entryPath)
            semaphore.signal()
        }
        semaphore.wait()
        return choice
    }
}
