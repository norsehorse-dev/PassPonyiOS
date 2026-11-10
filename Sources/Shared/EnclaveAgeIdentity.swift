import AgePonyCore
import Foundation

/// An age P-256 identity whose private operation is performed by this device.
/// The persisted data is an opaque, device-bound CryptoKit representation.
enum EnclaveAgeIdentity {
    private static let enabledKey = "passpony.enclaveAge.enabled"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: StorePaths.appGroupID) ?? .standard
    }
    private static var file: URL {
        StorePaths.container.appendingPathComponent("age-enclave-key")
    }

    static var isEnabled: Bool {
        defaults.bool(forKey: enabledKey) || FileManager.default.fileExists(atPath: file.path)
    }

    enum SetupError: Error {
        case alreadyExists
    }

    /// Explicit user action only. Never replace a device key: old ciphertext
    /// may depend on it. Store the representation before enabling the backend.
    static func create() throws -> String {
        guard !isEnabled, !FileManager.default.fileExists(atPath: file.path) else {
            throw SetupError.alreadyExists
        }
        let generated = try SecureEnclaveKeyAgreement.generate(protection: .userPresence)
        let agreement = SecureEnclaveKeyAgreement(dataRepresentation: generated.dataRepresentation)
        let identity = try TagIdentity.classic(publicKey: generated.publicUncompressed, p256: agreement)
        try generated.dataRepresentation.write(to: file, options: [.withoutOverwriting, .completeFileProtection])
        defaults.set(true, forKey: enabledKey)
        return identity.recipient.toBech32()
    }

    static func load() throws -> TagIdentity {
        let representation = try Data(contentsOf: file)
        let agreement = SecureEnclaveKeyAgreement(dataRepresentation: representation)
        return try TagIdentity.classic(publicKey: agreement.publicUncompressed(), p256: agreement)
    }
}
