import XCTest

final class ActionButtonSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
    }

    func testActionButtonDestinationCanBeConfigured() {
        app.buttons["Settings"].tap()

        let hardwareTriggerLink = app.buttons["hardwareTriggerSettingsLink"]
        XCTAssertTrue(hardwareTriggerLink.waitForExistence(timeout: 5))
        hardwareTriggerLink.tap()

        XCTAssertTrue(app.navigationBars["Action Button & Shortcuts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openShortcutsAppButton"].exists)

        let historyDestination = app.buttons["Save to History Only"]
        XCTAssertTrue(historyDestination.waitForExistence(timeout: 5))
        historyDestination.tap()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Save to History Only"].waitForExistence(timeout: 5))
    }
}
