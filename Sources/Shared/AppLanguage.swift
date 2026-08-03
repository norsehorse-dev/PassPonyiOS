import Foundation
import ObjectiveC

/// In-app language override, shared with the autofill extension via the app
/// group. Empty string means "follow the system language".
///
/// SwiftUI Text resolves against Bundle.main, whose language is fixed at
/// launch, so an environment locale alone cannot switch the catalog lookups
/// live. The mechanism here (the PGPony pattern, AppState.swift v7.1.1)
/// re-points Bundle.main's localizedString lookup at the selected language's
/// .lproj; the root view's .id() rebuild then re-evaluates every Text
/// immediately. Formatted strings go through L(_:) below, which resolves the
/// per-language bundle directly and therefore works in both processes.
enum AppLanguage {
    static let defaultsKey = "passpony.language"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: StorePaths.appGroupID) ?? .standard
    }

    /// The stored override; "" when following the system language.
    static var current: String {
        defaults.string(forKey: defaultsKey) ?? ""
    }

    static var locale: Locale {
        current.isEmpty ? .autoupdatingCurrent : Locale(identifier: current)
    }

    /// The .lproj sub-bundle for the override, or .main when following the
    /// system language.
    static var bundle: Bundle {
        guard !current.isEmpty,
              let bundle = Bundle.languageBundle(for: current)
        else { return .main }
        return bundle
    }

    /// Install the stored override for this process. Call once at launch
    /// (app and extension entry points) so lookups start in the right
    /// language.
    static func activate() {
        apply(current)
    }

    /// Persist a new choice and install it. The app calls this through
    /// AppModel.language's didSet so the UI reacts in the same beat.
    static func select(_ code: String) {
        if code.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(code, forKey: defaultsKey)
        }
        apply(code)
    }

    /// Point this process at `code` ("" clears the override). Also mirrors
    /// the choice into AppleLanguages so UIKit surfaces and the next launch
    /// agree with the in-app choice.
    static func apply(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        Bundle.setAppLanguage(code)
    }
}

/// Localized string that honors the in-app language override.
func L(_ keyAndValue: String.LocalizationValue) -> String {
    String(localized: keyAndValue, bundle: AppLanguage.bundle, locale: AppLanguage.locale)
}

// MARK: - Bundle.main override

private var kAppLanguageBundleKey: UInt8 = 0
private var kAppLanguageCodeKey: UInt8 = 0

/// Bundle subclass whose localized-string lookup resolves against the
/// selected language's .lproj, falling back to the normal (super) lookup
/// when no per-language bundle is associated. It adds NO stored properties
/// (the per-language bundle is held as an associated object), so it is safe
/// to install on the existing Bundle.main instance via object_setClass.
private final class AppLanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let langBundle = objc_getAssociatedObject(self, &kAppLanguageBundleKey) as? Bundle {
            return langBundle.localizedString(forKey: key, value: value, table: tableName)
        }
        if let code = objc_getAssociatedObject(self, &kAppLanguageCodeKey) as? String {
            // No physical .lproj matched the override. Newer Xcode compiles
            // the string catalog into a single .loctable with no per-language
            // folders at all, so resolve with an explicit localizations list;
            // CFBundle handles both the .loctable and .strings layouts.
            let fallback = (value?.isEmpty == false) ? value! : key
            if #available(iOS 18.4, *) {
                if let resolved = CFBundleCopyLocalizedStringForLocalizations(
                    CFBundleGetMainBundle(),
                    key as CFString,
                    fallback as CFString,
                    tableName.map { $0 as CFString },
                    [code] as CFArray
                ) as String? {
                    return resolved
                }
            }
            // An explicit English selection with nothing resolvable: the
            // catalog is English-keyed, so the key (or the caller's explicit
            // value) IS the English string. Falling through to super would
            // resolve via the launch-time language instead.
            if code.hasPrefix("en") {
                return fallback
            }
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Route Bundle.main's localized-string lookups through `code`'s .lproj.
    /// Swaps the main bundle's class once (idempotent), then updates the
    /// associated per-language bundle. Passing "" clears the override.
    static func setAppLanguage(_ code: String) {
        if !(Bundle.main is AppLanguageBundle) {
            object_setClass(Bundle.main, AppLanguageBundle.self)
        }
        objc_setAssociatedObject(
            Bundle.main,
            &kAppLanguageBundleKey,
            code.isEmpty ? nil : languageBundle(for: code),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        objc_setAssociatedObject(
            Bundle.main,
            &kAppLanguageCodeKey,
            code.isEmpty ? nil : code,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// The .lproj bundle for `code`: exact code first ("pt-BR.lproj"), then
    /// the language-only prefix ("pt.lproj"), then nil.
    static func languageBundle(for code: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        let langOnly = String(code.prefix(2))
        if langOnly != code,
           let path = Bundle.main.path(forResource: langOnly, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return nil
    }
}
