// Unlock policy shared by app and extension via the app group — the
// PGPony 5-minute cache pattern applied to store access. Within the grace
// window, QuickType fills instantly and the app opens unlocked; outside it,
// biometric/passcode auth is required (system LAContext sheet).
//
// This gates *access*; it does not yet encrypt the identities file itself.
// Passphrase-protected identities (age -p) layer under this later, at which
// point the grace window guards the cached passphrase instead.

import Foundation
import LocalAuthentication

enum UnlockGate {
    /// Grace period between required auths. Configurable in settings later;
    /// 5 minutes is the PGPony default users already know.
    static let gracePeriod: TimeInterval = 5 * 60

    private static let lastUnlockKey = "passpony.lastUnlock"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: StorePaths.appGroupID) ?? .standard
    }

    /// True while a prior auth is still within the grace window.
    static var isFresh: Bool {
        let last = defaults.double(forKey: lastUnlockKey)
        return last > 0 && Date().timeIntervalSince1970 - last < gracePeriod
    }

    static func markUnlocked() {
        defaults.set(Date().timeIntervalSince1970, forKey: lastUnlockKey)
    }

    /// The panic-lock action and background-expiry both land here.
    static func lock() {
        defaults.removeObject(forKey: lastUnlockKey)
    }

    /// Present the system auth sheet (Face ID / Touch ID / passcode).
    /// On devices without any protection configured (fresh simulator),
    /// auth is treated as passed — development convenience only; real
    /// devices always have at least a passcode path.
    static func authenticate(reason: String = "Unlock your password store") async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            markUnlocked()
            return true
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if ok { markUnlocked() }
            return ok
        } catch {
            return false
        }
    }
}
