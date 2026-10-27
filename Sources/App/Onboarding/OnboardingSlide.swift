import SwiftUI

/// One slide of the first-run carousel. Titles and bodies are
/// LocalizedStringKey so Text() resolves them through the catalog
/// (a String would render verbatim and skip it).
struct OnboardingSlide: Identifiable {
    /// The optional interactive element rendered under the body text.
    enum Action {
        case none
        case languagePicker
        case formatPicker
        case importStore
        case tryPass
        case biometric
        case autofill
    }

    let id = UUID()
    let icon: String // SF Symbol name
    let iconTint: Color
    let title: LocalizedStringKey
    let body: LocalizedStringKey
    var action: Action = .none
}

enum OnboardingSlides {

    /// Computed (not stored) so the biometric slide can interpolate the
    /// current grace period into its body at render time.
    static var all: [OnboardingSlide] {
        [
            // Language first, like PGPony: on a fresh install the detected
            // language is already applied, so this usually renders in the
            // user's iOS language from the first frame.
            OnboardingSlide(
                icon: "globe",
                iconTint: .accentColor,
                title: "Language",
                body: "Choose the language you'd like to use.\n\nYou can change this anytime in Settings.",
                action: .languagePicker
            ),

            OnboardingSlide(
                icon: "key.fill",
                iconTint: .accentColor,
                title: "Welcome to PassPony",
                body: "PassPony speaks the same format as the pass and passage command-line tools: plain files, encrypted with your keys, synced with git."
            ),

            OnboardingSlide(
                icon: "archivebox.fill",
                iconTint: .accentColor,
                title: "Choose your format",
                body: "passage encrypts with modern age identities. pass encrypts with OpenPGP keys and works with existing pass stores.\n\nEach format keeps its own store, and you can switch anytime in Settings.",
                action: .formatPicker
            ),

            OnboardingSlide(
                icon: "square.and.arrow.down.fill",
                iconTint: .accentColor,
                title: "Bring your store",
                body: "Already using pass or passage? Clone your existing store from its git remote, or import your OpenPGP key files.\n\nStarting fresh? Just continue.",
                action: .importStore
            ),

            OnboardingSlide(
                icon: "plus.circle.fill",
                iconTint: .accentColor,
                title: "Add your first pass",
                body: "A pass is one encrypted file: the password on the first line, anything else after it.\n\nTry it now. This saves a real entry to your store.",
                action: .tryPass
            ),

            OnboardingSlide(
                // Icon is overridden at render time based on the device's
                // biometric type; this is the fallback.
                icon: "lock.shield.fill",
                iconTint: .accentColor,
                title: "Locked by default",
                body: "PassPony locks behind Face ID, Touch ID, or your passcode.\n\nAfter you unlock, it stays open for \(Int(UnlockGate.gracePeriod / 60)) minutes (shared with autofill), then locks again.",
                action: .biometric
            ),

            OnboardingSlide(
                icon: "keyboard.fill",
                iconTint: .accentColor,
                title: "Fill passwords anywhere",
                body: "Turn on autofill and your passes appear right in the QuickType bar when you sign in.\n\nYou can manage this anytime in iOS Settings under AutoFill & Passwords.",
                action: .autofill
            ),
        ]
    }
}
