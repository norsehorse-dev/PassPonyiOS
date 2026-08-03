import Foundation

/// User-facing messages for errors surfaced from the core.
///
/// The FFI error text originates in Rust and stays English: it mirrors the
/// CLI and remains the log/fallback form. Localization happens here, on the
/// Swift side, by mapping each error *case* to a catalog key. Reasons that
/// arrive pre-formed from Rust (`Unavailable`, `Other`, `Crypto`, `Io`) are
/// passed through untranslated inside a localized frame.
extension Error {
    /// A localized, user-presentable message for this error.
    var ponyMessage: String {
        switch self {
        case let error as CryptoError: return error.ponyMessage
        case let error as GitError: return error.ponyMessage
        case let error as StoreError: return error.ponyMessage
        default: return String(describing: self)
        }
    }
}

extension CryptoError {
    var ponyMessage: String {
        switch self {
        case .DecryptionFailed:
            return L("Couldn't decrypt this entry. The matching key may be missing or locked.")
        case .EncryptionFailed:
            return L("Couldn't encrypt the entry.")
        case .NoUsableKey:
            return L("No usable key. Import the key for this store in Settings.")
        case .Cancelled:
            return L("Operation canceled.")
        case .Unavailable(let reason):
            // Swift-side throw sites localize the reason before throwing;
            // Rust-side reasons pass through in English.
            return reason
        }
    }
}

extension GitError {
    var ponyMessage: String {
        switch self {
        case .NoRepository:
            return L("No git repository for this store.")
        case .NoRemote:
            return L("No remote is configured.")
        case .NonFastForward:
            return L("The remote has new changes — sync before pushing.")
        case .UpstreamRewritten:
            return L("The remote history was rewritten. Re-clone the store to continue.")
        case .DirtyWorkdir:
            return L("The store has local changes that aren't committed yet.")
        case .Other(let reason):
            return L("Git error: \(reason)")
        }
    }
}

extension StoreError {
    var ponyMessage: String {
        switch self {
        case .NoStore:
            return L("No store is open.")
        case .NotInStore:
            return L("This entry isn't in the store.")
        case .SneakyPath:
            return L("Invalid entry path.")
        case .Crypto(let reason):
            return L("Encryption error: \(reason)")
        case .Io(let reason):
            return L("File error: \(reason)")
        }
    }
}
