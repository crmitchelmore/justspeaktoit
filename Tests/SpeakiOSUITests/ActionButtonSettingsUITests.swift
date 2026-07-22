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

    func testModelPickersExposeCredentialReadiness() {
        app.buttons["Settings"].tap()

        let locationPicker = app.segmentedControls["transcriptionLocationPicker"]
        XCTAssertTrue(scrollUpUntilExists(locationPicker))

        let localModelPicker = app.descendants(matching: .any)["appleOnDeviceModelPicker"]
        XCTAssertTrue(localModelPicker.waitForExistence(timeout: 5))
        localModelPicker.tap()

        let noKeyStatus = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "No API key required")
        ).firstMatch
        XCTAssertTrue(noKeyStatus.waitForExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        locationPicker.buttons["Remote"].tap()

        let remoteModelPicker = app.descendants(matching: .any)["remoteStreamingModelPicker"]
        XCTAssertTrue(remoteModelPicker.waitForExistence(timeout: 5))
        remoteModelPicker.tap()

        let readyOrMissingStatus = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "API key is set",
                "API key is not set"
            )
        ).firstMatch
        XCTAssertTrue(readyOrMissingStatus.waitForExistence(timeout: 5))
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
