import Foundation

/// Whether this device's age identities are backed up (2.0): an
/// encrypted `.passpony` backup or a plain identities export written since
/// the identities file last gained an identity. Per-device UI state in the
/// app group, never synced and never in the core. Absent reads as "not
/// backed up", which is right for anyone coming from 1.x.
enum KeyBackupState {
    static let key = "passpony.ageIdentitiesBackedUp"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: StorePaths.appGroupID) ?? .standard
    }

    static var backedUp: Bool { defaults.bool(forKey: key) }

    static func markBackedUp() { defaults.set(true, forKey: key) }

    /// The identities file gained an identity; the last backup no longer covers it.
    static func markChanged() { defaults.set(false, forKey: key) }
}
