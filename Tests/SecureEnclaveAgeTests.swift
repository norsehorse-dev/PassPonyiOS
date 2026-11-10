import XCTest
import AgePonyCore
@testable import PassPony

final class SecureEnclaveAgeTests: XCTestCase {
    // Gopass 1.17.4 encrypted this public dummy text for a dummy P-256
    // identity whose scalar is 1. It contains no real secrets.
    func testDecryptsGopassTaggedRecipient() throws {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 1
        let identity = try TagIdentity.softwareClassic(scalar: scalar)
        let engine = AgePonyEngine(enclaveIdentity: identity)
        let fixture = Data(base64Encoded: "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSB4RHRBRjR3UTdSdGxaVENrb1VqS2JERkl6Z2VJK2lUd2lEKzFhOXlSRURvCmI0L21UTkNUeDVLengwTUdvNUtVRXRzL09GZytEWitzc0hoOGYxSVZNUHMKLT4gcDI1NnRhZyB3QmFOdXcgQk5wUVQzU2tUT0VkcmFVYXo3NUYwYXV1VmkzMUgvNm1pcmZDZFZRa0Z2ZUdnUXZycTZyL0kxLzlwdWlVdWNvMmJ0R0VZN1kwTmFsVEVIaHJwdUFNT0pZCkRmQ0tWR1pTT25DTm9WZmt4L3ZFanZTQmVaYnE2TXpYVjJXY3gvUjVSOWsKLT4gcDI1NnRhZyBpaWE2SFEgQk9pY1RBZnN6dEtMdjZuY203ZUxIU1dyYmNpbEU4RTMzWWpWdVJ1Q0RvVGVDSUU1TEw3eHQ5bVdrckZtUmJRWjZWaTFFMnpVQVdBMmJmaGdJN2RDbHBBCnNPWjF0c3VWQ2F2bzRCQ2EwaG0xczhqR3loYmVOMEsrRURSWEpGMTB5ZWcKLS0tIDNBV0hxZFcvaHJraUV2RmJsczNCUlYwRkhSdzVLZ3d3MEFEVEgrSU1WQmMKZH11rFD0HyYx8uR/+xbDNLCCsDCvlj7cIEUKOydNaMl8X3PPHexHWtjgTWoXWJV+qa44AVY=")!
        XCTAssertEqual(try engine.decrypt(ciphertext: fixture), Data("passpony-tag-fixture\n".utf8))
    }

    func testEncryptsForTaggedAndSoftwareRecipients() throws {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 1
        let hardware = try TagIdentity.softwareClassic(scalar: scalar)
        let software = X25519Identity.generate()
        let engine = AgePonyEngine(enclaveIdentity: hardware)
        let message = Data("test secret\n".utf8)
        let ciphertext = try engine.encrypt(plaintext: message, recipients: [
            hardware.recipient.toBech32(), software.ageRecipient
        ])
        XCTAssertEqual(try engine.decrypt(ciphertext: ciphertext), message)
        XCTAssertEqual(try Age.decrypt(ciphertext: ciphertext, identities: [software]), message)
    }

    func testEnablingEnclavePreservesAccessToSoftwareEntries() throws {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 1
        let hardware = try TagIdentity.softwareClassic(scalar: scalar)
        let software = X25519Identity.generate()
        let oldEngine = AgePonyEngine(identities: [software])
        let combined = AgePonyEngine(enclaveIdentity: hardware, softwareIdentities: [software])
        let oldEntry = try oldEngine.encrypt(plaintext: Data("existing".utf8), recipients: [])
        XCTAssertEqual(try combined.decrypt(ciphertext: oldEntry), Data("existing".utf8))
        let newEntry = try combined.encrypt(plaintext: Data("new".utf8), recipients: [])
        XCTAssertEqual(try combined.decrypt(ciphertext: newEntry), Data("new".utf8))
        XCTAssertThrowsError(try oldEngine.decrypt(ciphertext: newEntry))
    }

    func testRejectsInvalidRecipient() throws {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 1
        let engine = AgePonyEngine(enclaveIdentity: try TagIdentity.softwareClassic(scalar: scalar))
        XCTAssertThrowsError(try engine.encrypt(plaintext: Data("secret".utf8), recipients: ["age1invalid"]))
    }

    func testExportForGopassWhenRequested() throws {
        guard let recipient = ProcessInfo.processInfo.environment["PASSPONY_INTEROP_RECIPIENT"] else {
            throw XCTSkip("External gopass fixture not configured")
        }
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 1
        let engine = AgePonyEngine(enclaveIdentity: try TagIdentity.softwareClassic(scalar: scalar))
        let tagged = "age1tag1qwe0kafsjrar4txm6heqnhpfuggzr0gvznz7fvygxrlq90u5mq2pysxtw6h"
        let ciphertext = try engine.encrypt(plaintext: Data("swift-to-gopass-fixture\n".utf8), recipients: [tagged, recipient])
        print("PASSPONY_INTEROP_CIPHERTEXT=\(ciphertext.base64EncodedString())")
    }
}
