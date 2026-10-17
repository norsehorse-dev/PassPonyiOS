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
        case let error as TotpError: return error.ponyMessage
        case let error as GenerateError: return error.ponyMessage
        case let error as BackupError: return error.ponyMessage
        case let error as MigrationError: return error.ponyMessage
        case let error as AgeIdentityStore.ImportError: return error.ponyMessage
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

extension TotpError {
    var ponyMessage: String {
        switch self {
        case .NotTotpUri, .NotHotpUri:
            return L("This isn't an otpauth:// one-time code link.")
        case .MissingCounter:
            return L("This counter-based (HOTP) link has no counter.")
        case .MissingSecret:
            return L("The code has no secret.")
        case .BadSecret:
            return L("The secret isn't valid base32.")
        case .BadAlgorithm(let name):
            return L("Unsupported algorithm: \(name)")
        case .BadNumber(let detail):
            return L("Invalid value: \(detail)")
        }
    }
}

extension GenerateError {
    var ponyMessage: String {
        switch self {
        case .BadLength(let min, let max):
            return L("Length must be between \(Int(min)) and \(Int(max)).")
        case .NoClasses:
            return L("Turn on at least one kind of character.")
        case .Entropy(let reason):
            return L("No random number source is available: \(reason)")
        }
    }
}

extension BackupError {
    var ponyMessage: String {
        switch self {
        case .NotABackup:
            return L("That file isn't a PassPony backup.")
        case .NewerVersion:
            return L("That backup was made by a newer version of PassPony. Update the app to restore it.")
        case .Damaged:
            return L("That backup is damaged or incomplete. Nothing was restored.")
        case .CodeLength:
            return L("A recovery code has 30 characters.")
        case .CodeCharacter:
            return L("That recovery code has a character codes never use.")
        case .CodeChecksum:
            return L("That recovery code has a typo. Check each group against what you wrote down.")
        case .RandomUnavailable:
            return L("This device couldn't generate a recovery code. Try again.")
        }
    }
}

extension MigrationError {
    var ponyMessage: String {
        switch self {
        case .NotMigrationUri:
            return L("That isn't a Google Authenticator export code.")
        case .MissingData, .BadBase64, .BadPayload:
            return L("That export code couldn't be read. Scan it again.")
        }
    }
}

extension AgeIdentityStore.ImportError {
    var ponyMessage: String {
        switch self {
        case .noUsableIdentity:
            return L("That file has no usable age identity.")
        case .passphraseRequired, .wrongPassphrase:
            return L("Wrong passphrase, or that is not a passphrase-protected file.")
        case .tooCostly:
            return L("That file needs more memory to unlock than this device allows.")
        }
    }
}
