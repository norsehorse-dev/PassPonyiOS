import SwiftUI

/// Git sync UI: status, clone, sync, push. Conflict resolution presents the
/// per-file sheet from docs/conflict-ux.md (PassPonyCore) — one choice per
/// conflicted entry, never a silent merge.
struct SyncView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var cloneURL = ""
    @State private var busy = false
    @State private var message: String?
    @State private var conflictPath: String?
    @State private var conflictContinuation: CheckedContinuation<ConflictChoice, Never>?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if model.git == nil {
                    cloneSection
                } else {
                    actionsSection
                }
                if let message {
                    Section { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if let st = model.syncStatus {
                LabeledContent("Unpushed", value: "\(st.ahead)")
                LabeledContent("Behind remote", value: "\(st.behind)")
                LabeledContent("Remote", value: st.hasRemote ? "configured" : "none")
            } else {
                Text("No git repository — clone a store or use local-only mode.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cloneSection: some View {
        Section("Clone existing store") {
            TextField("https://… or ssh://… (SSH lands with P2 follow-up)", text: $cloneURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Clone") {
                run {
                    _ = try GitSync.cloneFrom(
                        url: cloneURL,
                        dest: StorePaths.storeRoot.path,
                        depth: nil
                    )
                    await MainActor.run { model.openStore() }
                }
            }
            .disabled(cloneURL.isEmpty || busy)
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
                    let outcome = try git.sync(resolver: resolver)
                    await MainActor.run {
                        self.message = Self.describe(outcome)
                        model.refresh()
                    }
                }
            }
            .disabled(busy)
            Button("Push") {
                run {
                    try model.git?.push()
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
            } catch {
                await MainActor.run { self.message = String(describing: error) }
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
        case .upToDate: return "Already up to date."
        case .fastForwarded: return "Pulled changes from remote."
        case .rebased(let replayed): return "Merged cleanly (\(replayed) local change\(replayed == 1 ? "" : "s") replayed)."
        case .resolvedConflicts(let resolved, let keptBoth):
            var text = "Resolved \(resolved.count) conflict\(resolved.count == 1 ? "" : "s")."
            if !keptBoth.isEmpty {
                text += " Kept both for: \(keptBoth.joined(separator: ", "))."
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
