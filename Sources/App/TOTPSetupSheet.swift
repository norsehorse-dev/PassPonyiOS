import AVFoundation
import SwiftUI
import UIKit

/// Three ways to set up a one-time code, all ending in one canonical
/// `otpauth://totp/` URI built or validated by the core: paste a URI, type
/// the secret key with its account and issuer, or scan the QR code a site
/// shows during two-factor setup (which lands in the Paste tab with the
/// URI filled in, so the summary and the live preview are visible before
/// Use). Nothing here touches the entry; `onUse` hands the URI to the
/// calling view, which records it for its save.
///
/// The URI and the typed secret are secrets: plain @State, cleared with
/// the sheet, never persisted.
struct TOTPSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onUse: (String) -> Void

    private enum Tab: Hashable { case paste, key, scan }

    @State private var tab: Tab = .paste
    @State private var pasted = ""
    @State private var secret = ""
    @State private var secretRevealed = false
    @State private var account = ""
    @State private var issuer = ""
    @State private var advanced = false
    @State private var algorithm: TotpAlgorithm = .sha1
    @State private var digits: UInt32 = 6
    @State private var period = "30"
    @State private var showScanner = false
    @State private var cameraDenied = false

    private var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    /// The candidate URI for the current tab: success carries a URI the core
    /// accepted, failure carries the TotpError to explain, nil means nothing
    /// entered yet.
    private var candidate: Result<String, Error>? {
        switch tab {
        case .paste:
            let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Result<String, Error> {
                // TOTP or, since 2.0, HOTP (counter-based) links.
                try validateOtpUri(text)
                return text
            }
        case .key:
            guard !secret.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let trimmedIssuer = issuer.trimmingCharacters(in: .whitespaces)
            return Result<String, Error> {
                try totpBuildUri(
                    secret: secret,
                    account: account,
                    issuer: trimmedIssuer.isEmpty ? nil : trimmedIssuer,
                    algorithm: algorithm,
                    digits: digits,
                    period: UInt64(period.trimmingCharacters(in: .whitespaces)) ?? 0
                )
            }
        case .scan:
            return nil
        }
    }

    private var candidateURI: String? {
        if case .success(let uri)? = candidate { return uri }
        return nil
    }

    private var problem: String? {
        if case .failure(let error)? = candidate { return error.ponyMessage }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $tab) {
                        Text("Paste").tag(Tab.paste)
                        Text("Enter key").tag(Tab.key)
                        if hasCamera {
                            Text("Scan").tag(Tab.scan)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                }

                switch tab {
                case .paste:
                    Section {
                        TextField("otpauth://…", text: $pasted, axis: .vertical)
                            .lineLimit(2...4)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Paste the otpauth:// link the site offers during two-factor setup, or the output of pass otp uri on your desktop.")
                    }
                case .key:
                    Section {
                        HStack {
                            if secretRevealed {
                                TextField("Secret key", text: $secret)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Secret key", text: $secret)
                            }
                            Button {
                                secretRevealed.toggle()
                            } label: {
                                Image(systemName: secretRevealed ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }
                        TextField("Account", text: $account)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Issuer (site)", text: $issuer)
                            .autocorrectionDisabled()
                        DisclosureGroup("Advanced", isExpanded: $advanced) {
                            Picker("Algorithm", selection: $algorithm) {
                                Text(verbatim: "SHA-1").tag(TotpAlgorithm.sha1)
                                Text(verbatim: "SHA-256").tag(TotpAlgorithm.sha256)
                                Text(verbatim: "SHA-512").tag(TotpAlgorithm.sha512)
                            }
                            Picker("Digits", selection: $digits) {
                                Text(verbatim: "6").tag(UInt32(6))
                                Text(verbatim: "8").tag(UInt32(8))
                            }
                            .pickerStyle(.segmented)
                            TextField("Period (seconds)", text: $period)
                                .keyboardType(.numberPad)
                        }
                    }
                case .scan:
                    Section {
                        Button {
                            startScan()
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                        if cameraDenied {
                            Text("Camera access was denied. Paste the link or enter the key instead.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Button("Open app settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    } footer: {
                        Text("Point the camera at the QR code the site shows during two-factor setup.")
                    }
                }

                if let problem {
                    Section { Text(problem).foregroundStyle(.red).font(.footnote) }
                }

                if let uri = candidateURI, let summary = otpSummaryLine(uri: uri) {
                    Section("Preview") {
                        Text(summary)
                        if otpUriKind(uri: uri) == .totp {
                            // A one-line entry whose first line is the URI is the
                            // shape `pass otp insert` writes; the ring reads it as is.
                            TOTPRingView(content: Data("\(uri)\n".utf8))
                        } else {
                            // No preview for HOTP: showing a code would use up
                            // a counter value before the entry is saved.
                            Text("Counter-based code. Codes are shown on the entry, one at a time, when you ask for the next one.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Set up one-time code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this code") {
                        if let uri = candidateURI {
                            onUse(uri)
                            dismiss()
                        }
                    }
                    .disabled(candidateURI == nil)
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerScreen(
                    onDecoded: { text in
                        do {
                            try validateOtpUri(text)
                            pasted = text
                            tab = .paste
                            showScanner = false
                            return nil
                        } catch {
                            if text.hasPrefix("otpauth-migration:") {
                                return ScanFeedback(message: L("That's a Google Authenticator export. Use Import from Authenticator in the store list menu."))
                            }
                            return ScanFeedback(message: L("That QR code isn't a one-time code. \(error.ponyMessage)"))
                        }
                    },
                    onClose: { showScanner = false }
                )
            }
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

/// "Example:kevin · 6 digits · 30 s", the summary line every OTP surface shows.
func totpSummaryLine(_ summary: TotpSummary) -> String {
    L("\(summary.label) · \(Int(summary.digits)) digits · \(Int(summary.period)) s")
}
