// The P3 week-one spike, as runnable checks inside the extension process.
// Answers the open items from PassPonyCore docs/spike-corenfc-credential-
// extension.md empirically on-device. Remove after the spike memo is updated
// with the verdicts.

import AuthenticationServices
import CoreNFC
import CryptoTokenKit
import SwiftUI

struct SpikeChecksView: View {
    @State private var results: [(String, String)] = []

    var body: some View {
        List {
            Section("Spike: in-extension capabilities") {
                ForEach(results, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.caption).foregroundStyle(.secondary)
                        Text(item.1).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            Button("Run checks") { run() }
        }
        .navigationTitle("Week-one spike")
        .onAppear { run() }
    }

    private func run() {
        var out: [(String, String)] = []

        // 1. NFC availability in the extension process (expected: false).
        out.append((
            "NFCTagReaderSession.readingAvailable",
            "\(NFCTagReaderSession.readingAvailable)"
        ))

        // 2. CryptoTokenKit slot manager from the extension (the big one).
        //    Plug in a USB-C YubiKey first.
        if let mgr = TKSmartCardSlotManager.default {
            out.append(("TKSmartCardSlotManager.slotNames", "\(mgr.slotNames)"))
        } else {
            out.append((
                "TKSmartCardSlotManager.default",
                "nil (entitlement com.apple.security.smartcard missing or unsupported in extension)"
            ))
        }

        // 3. Token-backed keys visible via keychain? (PIV path)
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrAccessGroup as String: kSecAttrAccessGroupToken,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        out.append((
            "SecItemCopyMatching(token access group)",
            "status \(status)\(status == errSecItemNotFound ? " (no token keys visible)" : "")"
        ))
        query[kSecReturnAttributes as String] = nil

        results = out
    }
}
