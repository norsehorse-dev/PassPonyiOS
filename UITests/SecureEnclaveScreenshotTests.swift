import XCTest

final class SecureEnclaveScreenshotTests: XCTestCase {
    @MainActor
    func testSettingsShowsDeviceBoundAgeKey() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-seedDemoStore"]
        app.launch()

        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let createKey = app.buttons["Create Secure Enclave identity…"]
        for _ in 0..<5 where !createKey.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(createKey.waitForExistence(timeout: 10))
        XCTAssertTrue(createKey.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Secure Enclave age settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
