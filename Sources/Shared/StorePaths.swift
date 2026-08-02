import Foundation

/// One place for every path decision, shared by app and extension.
enum StorePaths {
    /// App-group container so the autofill extension sees the same store.
    /// Update the group id together with the entitlements files.
    static let appGroupID = "group.dev.norsehorse.passpony"

    static var container: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return url
        }
        // Simulator without provisioned app group: fall back to Documents so
        // development still works. Real devices always have the group.
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var storeRoot: URL {
        storeRoot(for: currentFormat)
    }

    /// Each format keeps its own store directory so switching is
    /// non-destructive. Passage keeps the original "store" name for
    /// continuity with existing installs.
    static func storeRoot(for format: StoreFormat) -> URL {
        switch format {
        case .passage:
            return container.appendingPathComponent("store", isDirectory: true)
        case .pass:
            return container.appendingPathComponent("pass-store", isDirectory: true)
        }
    }

    private static let formatKey = "passpony.storeFormat"

    /// The active store format, shared with the autofill extension via the
    /// app group. Defaults to passage (the wedge format).
    static var currentFormat: StoreFormat {
        get {
            let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
            return defaults.string(forKey: formatKey) == "pass" ? .pass : .passage
        }
        set {
            let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
            defaults.set(newValue == .pass ? "pass" : "passage", forKey: formatKey)
        }
    }
}
