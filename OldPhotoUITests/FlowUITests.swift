import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testOpenDirectlyToFinderThenScanAndEditFrames() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-album", "-demo-empty", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let shutter = app.buttons["finder-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 8))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: shutter)
        waitForExpectations(timeout: 6)
        shutter.tap()
        let tray = app.buttons["finder-library"]
        XCTAssertTrue(tray.exists)
        let status = app.staticTexts["finder-status"]
        let pattern = NSPredicate(format: "label == %@", "4 photos scanned")
        expectation(for: pattern, evaluatedWith: status)
        waitForExpectations(timeout: 12)
        tray.tap()
        let album = app.buttons["album-row"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        let tile = app.buttons["photo-tile"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        XCTAssertTrue(app.buttons["edit-frame"].waitForExistence(timeout: 5))
        app.buttons["edit-frame"].tap()
        XCTAssertTrue(app.buttons["crop-done"].waitForExistence(timeout: 5))
        app.buttons["crop-done"].tap()
        XCTAssertTrue(app.buttons["share-comparison"].exists)
    }

    func testSuggestedYearNeedsConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-album", "-shot-detail"]
        app.launch()
        let suggestion = app.buttons["confirm-year"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 9))
        suggestion.tap()
        XCTAssertTrue(app.buttons["edit-date"].waitForExistence(timeout: 4))
        XCTAssertFalse(suggestion.exists)
    }

    func testExpiredTrialStillExposesFullResolutionExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-album", "-shot-detail", "-expired"]
        app.launch()
        let actions = app.buttons["detail-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 9))
        XCTAssertFalse(app.sliders["strength"].exists)
        actions.tap()
        XCTAssertTrue(app.buttons["export-full"].waitForExistence(timeout: 4))
    }

    func testDeniedCameraOffersImportWithoutReads() {
        let app = XCUIApplication()
        app.launchArguments = ["-camera-denied"]
        app.launch()
        XCTAssertTrue(app.buttons["denied-import"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["finder-library"].exists)
    }
}
