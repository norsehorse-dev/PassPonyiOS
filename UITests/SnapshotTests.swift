//
//  SnapshotTests.swift
//  PassPonyUITests
//
//  Drives the app through the screens used for App Store screenshots. Run by
//  fastlane snapshot through the PassPonySnapshots scheme; the PassPony
//  scheme doesn't include this target, so normal builds never run it.
//
//  The app is launched with -seedDemoStore, which skips the tour and fills
//  an empty passage store with the DEBUG demo entries (AppModel's
//  seedDemoStore). Rows are found by those entry names ("web",
//  "github.com"), which are data and read the same in every language;
//  buttons are found by accessibilityIdentifier, which is never translated.
//

import XCTest

final class SnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-seedDemoStore"]
        app.launch()

        // 1. The store, folders first like `pass ls`. The sync button is
        // only hittable once nothing (an unlock prompt) covers the list.
        let web = app.staticTexts["web"]
        XCTAssertTrue(web.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["syncButton"].isHittable, "something covers the store list")
        snapshot("01Store")

        // 2. An entry: password, fields, one-time code, passkey.
        web.tap()
        let github = app.staticTexts["github.com"]
        XCTAssertTrue(github.waitForExistence(timeout: 10))
        github.tap()
        XCTAssertTrue(app.staticTexts["pony"].firstMatch.waitForExistence(timeout: 10))
        sleep(2) // let the one-time code ring settle
        snapshot("02Entry")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 3. Sync: your own git remote, HTTPS or SSH.
        let sync = app.buttons["syncButton"]
        XCTAssertTrue(sync.waitForExistence(timeout: 10))
        sync.tap()
        let syncDone = app.buttons["syncDoneButton"]
        XCTAssertTrue(syncDone.waitForExistence(timeout: 10))
        snapshot("03Sync")
        syncDone.tap()

        // 4. Keys backup, with a recovery code on screen.
        let more = app.buttons["moreMenu"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let backup = app.buttons["backupKeysButton"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let create = app.buttons["createBackupButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        sleep(1)
        snapshot("04Backup")
        app.buttons["backupDoneButton"].tap()

        // 5. The password generator.
        let add = app.buttons["addButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let generator = app.buttons["generatorSettingsButton"]
        XCTAssertTrue(generator.waitForExistence(timeout: 10))
        generator.tap()
        XCTAssertTrue(app.buttons["generatorCancelButton"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("05Generator")
    }
}
