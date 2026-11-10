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
    @MainActor
    func testOnboardingOffersDeviceKeyBeforeFirstEntry() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-showOnboardingForTesting"]
        app.launch()
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        for _ in 0..<3 { next.tap() }
        XCTAssertTrue(app.staticTexts["Protect this device's key"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Use Secure Enclave"].exists || app.staticTexts["Secure Enclave key ready"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Device key onboarding"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
