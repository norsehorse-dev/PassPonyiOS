// The engine seam. passage stores run on the real AgePonyCore engine;
// pass stores still use the DEV byte-flip stand-in until NorseHorsePGPCore
// is wired (next engine, same seam).

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
            fatalError("passage engine unavailable")
            #endif
        case .pass:
            #if DEBUG
            return DevFlipEngine()
            #else
            fatalError("OpenPGP engine not wired yet — pass stores are dev-only.")
            #endif
        }
    }
}

// DEV ONLY — NOT CRYPTO. A reversible byte-flip used solely where a real
// engine isn't wired yet (pass stores). Release builds trap instead.
final class DevFlipEngine: CryptoBackend {
    func encrypt(plaintext: Data, recipients: [String]) throws -> Data {
        Data(plaintext.map { ~$0 })
    }

    func decrypt(ciphertext: Data) throws -> Data {
        Data(ciphertext.map { ~$0 })
    }
}
