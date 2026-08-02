// DEV ONLY — NOT CRYPTO.
// A reversible byte-flip standing in for a real engine so the whole app runs
// in the simulator before NorseHorsePGPCore / the AgePony engine are wired.
// The real engines conform to the same generated `CryptoBackend` protocol;
// swapping them in is a one-line change in EngineProvider.
//
// This engine must never ship: EngineProvider traps in release builds.

import Foundation

final class DevFlipEngine: CryptoBackend {
    func encrypt(plaintext: Data, recipients: [String]) throws -> Data {
        Data(plaintext.map { ~$0 })
    }

    func decrypt(ciphertext: Data) throws -> Data {
        Data(ciphertext.map { ~$0 })
    }
}

enum EngineProvider {
    /// The single seam where real engines plug in:
    /// - passage stores → AgePony Swift engine
    /// - pass stores    → NorseHorsePGPCore
    static func engine(for format: StoreFormat) -> CryptoBackend {
        #if DEBUG
        return DevFlipEngine()
        #else
        fatalError("Real crypto engines not wired yet — dev builds only.")
        #endif
    }
}
