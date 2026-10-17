import AVFoundation
import SwiftUI

/// Collects the QR codes of one Google Authenticator export: they share a
/// batch id, each with its own index out of the batch size.
struct MigrationCollector {
    enum Outcome: Equatable {
        case added(scanned: Int, total: Int)
        case duplicate(scanned: Int, total: Int)
        case otherExport
    }

    private(set) var parts: [Int: MigrationBatch] = [:]
    private var batchId: Int64?
    private(set) var total = 0

    var scanned: Int { parts.count }
    var complete: Bool { total > 0 && parts.count >= total }

    mutating func add(_ batch: MigrationBatch) -> Outcome {
        if let id = batchId, id != batch.batchId { return .otherExport }
        batchId = batch.batchId
        total = max(total, Int(batch.batchSize), 1)
        let index = Int(batch.batchIndex)
        if parts[index] != nil { return .duplicate(scanned: parts.count, total: total) }
        parts[index] = batch
        return .added(scanned: parts.count, total: total)
    }

    var accounts: [MigrationAccount] { parts.keys.sorted().flatMap { parts[$0]!.accounts } }
    var skipped: [MigrationSkipped] { parts.keys.sorted().flatMap { parts[$0]!.skipped } }

    mutating func clear() {
        parts = [:]
        batchId = nil
        total = 0
    }
}

/// Import the accounts of a Google Authenticator export ("Transfer
/// accounts" in that app): scan every QR code of the export, pick the
/// accounts, name the entries, and each becomes an OTP-only entry like
/// `pass otp insert` writes, one commit each. Every account carries its
/// secret, so all of this is plain @State that goes with the view.
struct AuthenticatorImportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let account: MigrationAccount
        var name: String
        var selected = true
        var id: String { account.uri }
    }

    @State private var collector = MigrationCollector()
    @State private var rows: [Row] = []
    @State private var pasted = ""
    @State private var showScanner = false
    @State private var cameraDenied = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        startScan()
                    } label: {
                        Label("Scan export codes", systemImage: "qrcode.viewfinder")
                    }
                    if cameraDenied {
                        Text("Camera access was denied. Paste the link or enter the key instead.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    TextField("or paste an otpauth-migration:// link", text: $pasted)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add link") {
                        message = accept(pasted)?.message
                        pasted = ""
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                    if collector.total > 0 {
                        Text("\(collector.scanned) of \(collector.total) codes scanned")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("In Google Authenticator, choose Transfer accounts, then Export accounts. Scan every QR code it shows. Each account you pick becomes its own one-time code entry.")
                }

                if !rows.isEmpty {
                    Section("Accounts") {
                        ForEach($rows) { $row in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: $row.selected) {
                                    Text(verbatim: describe(row.account))
                                }
                                TextField("Entry name", text: $row.name)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .disabled(!row.selected)
                                if row.selected, let problem = problem(for: row) {
                                    Text(problem).font(.footnote).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }

                if !collector.skipped.isEmpty {
                    Section("Not imported") {
                        ForEach(collector.skipped.indices, id: \.self) { i in
                            let s = collector.skipped[i]
                            Text(verbatim: "\(s.label): \(skipReason(s.reason))")
                                .font(.footnote)
                        }
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote) }
                }

                if !rows.isEmpty {
                    Section {
                        Button("Start over", role: .destructive) {
                            collector.clear()
                            rows = []
                            message = nil
                        }
                    }
                }
            }
            .navigationTitle("Import from Authenticator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Import \(chosen.count) entries")) { importChosen() }
                        .disabled(chosen.isEmpty || chosen.contains { problem(for: $0) != nil })
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerScreen(
                    onDecoded: { text in
                        let feedback = accept(text)
                        if feedback == nil { showScanner = false }
                        return feedback
                    },
                    onClose: { showScanner = false }
                )
            }
        }
    }

    private var chosen: [Row] { rows.filter(\.selected) }

    private func describe(_ a: MigrationAccount) -> String {
        var parts = [a.issuer, a.account.isEmpty ? nil : a.account].compactMap { $0 }
        if a.kind == .hotp { parts.append(L("counter-based")) }
        return parts.joined(separator: " · ")
    }

    private func skipReason(_ reason: MigrationSkipReason) -> String {
        switch reason {
        case .md5: return L("uses MD5, which PassPony and pass-otp don't support")
        case .emptySecret: return L("has no secret")
        default: return L("uses settings PassPony doesn't support")
        }
    }

    private func cleaned(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func problem(for row: Row) -> String? {
        let name = cleaned(row.name)
        if name.isEmpty { return L("Give this entry a name.") }
        let earlier = rows.prefix { $0.id != row.id }.filter(\.selected).map { cleaned($0.name) }
        if earlier.contains(name) { return L("Another account here has the same name.") }
        if model.hasEntry(name) { return L("An entry with this name already exists.") }
        return nil
    }

    /// Parse one code; nil when the export is complete (closes the scanner).
    private func accept(_ text: String) -> ScanFeedback? {
        let batch: MigrationBatch
        do {
            batch = try migrationParse(uri: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return ScanFeedback(message: error.ponyMessage)
        }
        let outcome = collector.add(batch)
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = collector.accounts.map { account in
            previous[account.uri] ?? Row(account: account, name: account.suggestedName)
        }
        switch outcome {
        case .otherExport:
            return ScanFeedback(message: L("That code is from a different export. Finish this one or start over."))
        case .duplicate(let scanned, let total):
            return ScanFeedback(message: L("Already scanned. \(scanned) of \(total) codes so far."), isError: false)
        case .added(let scanned, let total):
            return collector.complete
                ? nil
                : ScanFeedback(message: L("\(scanned) of \(total) codes scanned"), isError: false)
        }
    }

    private func importChosen() {
        let items = chosen.map { (name: cleaned($0.name), uri: $0.account.uri) }
        do {
            let written = try model.addOtpEntries(items)
            collector.clear()
            rows = []
            message = L("Imported \(written) entries.")
        } catch {
            message = error.ponyMessage
        }
    }

    private func startScan() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showScanner = true } else { cameraDenied = true }
                }
            }
        default:
            cameraDenied = true
        }
    }
}
