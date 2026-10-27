// The engine seam. passage stores run on the real AgePonyCore engine;
// pass stores run on PGPonyEngine (NorseHorsePGPCore) once a key is
// imported. With no usable key the provider hands back MissingKeyEngine,
// which throws, so a missing key is an error message and never a crash.

import Foundation

enum EngineProvider {
    static func engine(for format: StoreFormat) -> CryptoBackend {
        switch format {
        case .passage:
            if let engine = try? AgeIdentityStore.loadOrCreateEngine() {
                return engine
            }
            #if DEBUG
            return DevFlipEngine()
            #else
            return MissingKeyEngine()
            #endif
        case .pass:
            PGPKeyStore.ensureDirectory()
            if PGPKeyStore.hasKeys,
               let engine = try? PGPonyEngine(
                   keyDirectory: PGPKeyStore.keyDirectory,
                   passphrase: PassphraseCache.load()
               ) {
                return engine
            }
            // No keys yet is a normal state (picking pass during onboarding,
            // switching format in Settings, before the key import). Every
            // store open reaches here via the passkey index rebuild, so this
            // must throw, never trap, in every build.
            return MissingKeyEngine()
        }
    }
}

/// Stands in when a store's keys aren't available. Every call throws
/// NoUsableKey, which callers already surface as "import the key for this
/// store", and the passkey index rebuild skips quietly.
final class MissingKeyEngine: CryptoBackend {
    func encrypt(plaintext: Data, recipients: [String]) throws -> Data {
        throw CryptoError.NoUsableKey
    }

    func decrypt(ciphertext: Data) throws -> Data {
        throw CryptoError.NoUsableKey
    }
}

// DEV ONLY — NOT CRYPTO. A reversible byte-flip, DEBUG builds only, for a
// passage store on a simulator where the age identity can't be created.
// Release builds get MissingKeyEngine instead.
final class DevFlipEngine: CryptoBackend {
    func encrypt(plaintext: Data, recipients: [String]) throws -> Data {
        Data(plaintext.map { ~$0 })
    }

    func decrypt(ciphertext: Data) throws -> Data {
        Data(ciphertext.map { ~$0 })
    }
}
