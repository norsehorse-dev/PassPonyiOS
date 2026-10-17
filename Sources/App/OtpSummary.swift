import Foundation

/// One summary line for either kind of one-time code: TOTP reads
/// "Example:kevin · 6 digits · 30 s", HOTP "Example:kevin · 6 digits ·
/// counter 4". Nil when the URI carries no code the core accepts.
func otpSummaryLine(uri: String) -> String? {
    switch otpUriKind(uri: uri) {
    case .totp?: return (try? totpDescribe(uri: uri)).map(totpSummaryLine)
    case .hotp?: return (try? hotpDescribe(uri: uri)).map(hotpSummaryLine)
    case nil: return nil
    }
}

/// The same line for the code an entry already carries.
func entryOtpSummaryLine(content: Data) -> String? {
    switch entryOtpKind(content: content) {
    case .totp?: return entryTotpSummary(content: content).map(totpSummaryLine)
    case .hotp?: return entryHotpSummary(content: content).map(hotpSummaryLine)
    case nil: return nil
    }
}

func hotpSummaryLine(_ summary: HotpSummary) -> String {
    L("\(summary.label) · \(Int(summary.digits)) digits · counter \(Int(summary.counter))")
}

/// Validate a pasted or scanned code link of either kind; throws the core's
/// TotpError when it isn't one.
func validateOtpUri(_ uri: String) throws {
    switch otpUriKind(uri: uri) {
    case .totp?: _ = try totpDescribe(uri: uri)
    case .hotp?: _ = try hotpDescribe(uri: uri)
    case nil: _ = try totpDescribe(uri: uri) // throws NotTotpUri
    }
}
