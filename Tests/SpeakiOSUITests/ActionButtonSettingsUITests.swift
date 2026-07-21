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
        XCTAssertTrue(scrollUpUntilExists(hardwareTriggerLink))
        hardwareTriggerLink.tap()

        XCTAssertTrue(app.navigationBars["Action Button & Shortcuts"].waitForExistence(timeout: 5))

        let historyDestination = app.buttons["Save to History Only"]
        XCTAssertTrue(historyDestination.waitForExistence(timeout: 5))
        historyDestination.tap()

        let clipboardGuidance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Do not add a separate Copy to Clipboard action")
        ).firstMatch
        XCTAssertTrue(scrollUpUntilExists(clipboardGuidance))
        XCTAssertTrue(scrollUpUntilExists(app.buttons["openShortcutsAppButton"]))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Save to History Only"].waitForExistence(timeout: 5))
    }

    private func scrollUpUntilExists(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 1) {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }
        return false
    }
}
