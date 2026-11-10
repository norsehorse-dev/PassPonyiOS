#!/usr/bin/env bash
# Run the actual age engine's format tests without building the app's Rust
# framework. A software P-256 test key stands in for the device's Enclave.
set -euo pipefail
root="$(pwd)"
work="$root/build/age-interop"
mkdir -p "$work/Sources/AgeInterop" "$work/Tests/AgeInteropTests"
awk '/^enum AgeIdentityStore / { exit } { print }' Sources/Shared/AgePonyEngine.swift > "$work/Sources/AgeInterop/AgePonyEngine.swift"
cp Sources/Shared/EnclaveAgeIdentity.swift "$work/Sources/AgeInterop/EnclaveAgeIdentity.swift"
cat > "$work/Sources/AgeInterop/FFIStub.swift" <<'SWIFT'
import Foundation
protocol CryptoBackend {
    func encrypt(plaintext: Data, recipients: [String]) throws -> Data
    func decrypt(ciphertext: Data) throws -> Data
}
enum CryptoError: Error { case NoUsableKey, EncryptionFailed, DecryptionFailed }
enum StorePaths {
    static let appGroupID = "test.passpony.interop"
    static let container = FileManager.default.temporaryDirectory
}
SWIFT
sed 's/@testable import PassPony/@testable import AgeInterop/' Tests/SecureEnclaveAgeTests.swift > "$work/Tests/AgeInteropTests/SecureEnclaveAgeTests.swift"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AgeInterop",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "AgePonyCore", path: "../../../AgePony")],
    targets: [
        .target(name: "AgeInterop", dependencies: [.product(name: "AgePonyCore", package: "AgePonyCore")]),
        .testTarget(name: "AgeInteropTests", dependencies: ["AgeInterop", .product(name: "AgePonyCore", package: "AgePonyCore")])
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
swift test --package-path "$work"
