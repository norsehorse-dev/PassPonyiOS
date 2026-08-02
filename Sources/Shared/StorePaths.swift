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
        container.appendingPathComponent("store", isDirectory: true)
    }
}
