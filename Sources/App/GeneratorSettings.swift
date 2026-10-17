import Foundation

/// The password generator's user-facing settings, as the generator sheet
/// edits them and as the app-group defaults remember them (per device, not
/// per store). The bounds and the default mirror pass-core's generate.rs:
/// 25 characters from every class with the full symbol set is pass's own
/// `generate` and what every PassPony build before 1.1 produced.
///
/// Every rule about what the settings mean lives in the core, reached
/// through `generatePassword`; this type only carries choices across.
struct GeneratorSettings: Equatable {
    enum Symbols: String, CaseIterable {
        case noSymbols = "none"
        case basic
        case full
    }

    var length: Int
    var lowercase: Bool
    var uppercase: Bool
    var digits: Bool
    var symbols: Symbols

    static let minLength = 8
    static let maxLength = 128

    /// pass's `generate` defaults, unchanged from 1.0.
    static let standard = GeneratorSettings(
        length: 25, lowercase: true, uppercase: true, digits: true, symbols: .full
    )

    /// At least one class, or there is nothing to draw from.
    var hasAnyClass: Bool { lowercase || uppercase || digits || symbols != .noSymbols }

    var isValid: Bool {
        hasAnyClass && (Self.minLength...Self.maxLength).contains(length)
    }

    /// The core's spec for these settings; the one place the two types meet.
    var spec: GeneratorSpec {
        let set: SymbolSet
        switch symbols {
        case .noSymbols: set = .noSymbols
        case .basic: set = .basic
        case .full: set = .full
        }
        return GeneratorSpec(
            length: UInt32(length),
            lowercase: lowercase,
            uppercase: uppercase,
            digits: digits,
            symbols: set
        )
    }

    // MARK: - Persistence

    private static let lengthKey = "passpony.generator.length"
    private static let lowercaseKey = "passpony.generator.lowercase"
    private static let uppercaseKey = "passpony.generator.uppercase"
    private static let digitsKey = "passpony.generator.digits"
    private static let symbolsKey = "passpony.generator.symbols"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: StorePaths.appGroupID) ?? .standard
    }

    /// Rebuild settings from stored values, any of which may be missing (a
    /// fresh install, or a key added after the user last saved). A missing
    /// value takes the default for that one field, an out-of-range length is
    /// clamped, and a combination with no class at all (only a corrupted
    /// store can produce it) falls back to [standard] whole, so generation
    /// never has nothing to draw from.
    static func load() -> GeneratorSettings {
        let d = defaults
        let length = d.object(forKey: lengthKey) as? Int ?? standard.length
        let settings = GeneratorSettings(
            length: min(max(length, minLength), maxLength),
            lowercase: d.object(forKey: lowercaseKey) as? Bool ?? standard.lowercase,
            uppercase: d.object(forKey: uppercaseKey) as? Bool ?? standard.uppercase,
            digits: d.object(forKey: digitsKey) as? Bool ?? standard.digits,
            symbols: Symbols(rawValue: d.string(forKey: symbolsKey) ?? "") ?? standard.symbols
        )
        return settings.hasAnyClass ? settings : standard
    }

    func save() {
        let d = Self.defaults
        d.set(length, forKey: Self.lengthKey)
        d.set(lowercase, forKey: Self.lowercaseKey)
        d.set(uppercase, forKey: Self.uppercaseKey)
        d.set(digits, forKey: Self.digitsKey)
        d.set(symbols.rawValue, forKey: Self.symbolsKey)
    }
}

/// The Generate button, over the core's generator since 1.1: one
/// implementation shared with Android and the desktop, OS entropy, uniform
/// draws, every enabled class present at least once. The 94-character
/// constant and the `SystemRandomNumberGenerator` loop that lived in
/// AddEntryView before are gone.
enum PasswordGenerator {
    /// One-tap Generate: the remembered settings, or pass's defaults.
    static func generate() -> String {
        (try? generatePassword(spec: GeneratorSettings.load().spec)) ?? ""
    }

    static func generate(_ settings: GeneratorSettings) throws -> String {
        try generatePassword(spec: settings.spec)
    }
}
