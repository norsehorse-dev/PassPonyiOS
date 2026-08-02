import UIKit

/// Clipboard policy per the threat model: local-only (no Handoff/universal
/// clipboard) and self-expiring (~45 s) via UIPasteboard's expiration option.
enum Clipboard {
    static let clearAfterSeconds: TimeInterval = 45

    static func copyEphemeral(_ data: Data) {
        let value = String(data: data, encoding: .utf8) ?? ""
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(clearAfterSeconds),
            ]
        )
    }
}
