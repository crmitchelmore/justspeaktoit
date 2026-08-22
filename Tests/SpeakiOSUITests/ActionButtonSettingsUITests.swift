import XCTest

final class ActionButtonSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Generous on purpose: these waits only cost time when an element is
    /// missing, and this class runs first in the UI bundle, on a simulator that
    /// is still cold on a loaded CI runner (issue #793).
    private static let launchTimeout: TimeInterval = 60
    private static let elementTimeout: TimeInterval = 15

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        // `launch()` returns when the process is up, not when the first screen
        // has rendered; tapping a tab that is not there yet fails the test
        // without a useful message.
        XCTAssertTrue(
            app.buttons["Settings"].waitForExistence(timeout: Self.launchTimeout),
            "The Settings tab did not appear within \(Int(Self.launchTimeout))s of launch"
        )
    }

    func testActionButtonDestinationCanBeConfigured() {
        app.buttons["Settings"].tap()

        let hardwareTriggerLink = app.buttons["hardwareTriggerSettingsLink"]
        XCTAssertTrue(scrollUpUntilExists(hardwareTriggerLink), "hardwareTriggerSettingsLink not found in Settings")
        hardwareTriggerLink.tap()

        XCTAssertTrue(
            app.navigationBars["Action Button & Shortcuts"].waitForExistence(timeout: Self.elementTimeout),
            "Action Button & Shortcuts screen did not open"
        )

        let historyDestination = app.buttons["Save to History Only"]
        XCTAssertTrue(
            historyDestination.waitForExistence(timeout: Self.elementTimeout),
            "Save to History Only destination not offered"
        )
        historyDestination.tap()

        let clipboardGuidance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Do not add a separate Copy to Clipboard action")
        ).firstMatch
        XCTAssertTrue(scrollUpUntilExists(clipboardGuidance), "Clipboard guidance not shown for the history choice")
        XCTAssertTrue(scrollUpUntilExists(app.buttons["openShortcutsAppButton"]), "openShortcutsAppButton not found")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["Save to History Only"].waitForExistence(timeout: Self.elementTimeout),
            "Settings did not reflect the chosen destination after going back"
        )
    }

    func testModelPickersExposeCredentialReadiness() {
        app.buttons["Settings"].tap()

        let locationPicker = app.segmentedControls["transcriptionLocationPicker"]
        XCTAssertTrue(scrollUpUntilExists(locationPicker), "transcriptionLocationPicker not found in Settings")

        let localModelPicker = app.descendants(matching: .any)["appleOnDeviceModelPicker"]
        XCTAssertTrue(
            localModelPicker.waitForExistence(timeout: Self.elementTimeout),
            "appleOnDeviceModelPicker not found"
        )
        localModelPicker.tap()

        let noKeyStatus = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "No API key required")
        ).firstMatch
        XCTAssertTrue(
            noKeyStatus.waitForExistence(timeout: Self.elementTimeout),
            "Local model picker did not state that no API key is required"
        )

        app.navigationBars.buttons.element(boundBy: 0).tap()
        locationPicker.buttons["Remote"].tap()

        let remoteModelPicker = app.descendants(matching: .any)["remoteStreamingModelPicker"]
        XCTAssertTrue(
            remoteModelPicker.waitForExistence(timeout: Self.elementTimeout),
            "remoteStreamingModelPicker not found after switching to Remote"
        )
        remoteModelPicker.tap()

        let readyOrMissingStatus = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "API key is set",
                "API key is not set"
            )
        ).firstMatch
        XCTAssertTrue(
            readyOrMissingStatus.waitForExistence(timeout: Self.elementTimeout),
            "Remote model picker did not state whether the API key is set"
        )
    }

    #if IOS_KEYBOARD_FEATURE
    func testKeyboardOnboardingExplainsSupportedSetup() {
        app.buttons["Settings"].tap()

        let keyboardSetupLink = app.buttons["keyboardSetupLink"]
        XCTAssertTrue(scrollUpUntilExists(keyboardSetupLink), "keyboardSetupLink not found in Settings")
        keyboardSetupLink.tap()

        XCTAssertTrue(
            app.navigationBars["Just Speak Keyboard"].waitForExistence(timeout: Self.elementTimeout),
            "Just Speak Keyboard screen did not open"
        )
        XCTAssertTrue(
            app.buttons["openKeyboardSettingsButton"].waitForExistence(timeout: Self.elementTimeout),
            "openKeyboardSettingsButton not found"
        )
        XCTAssertTrue(scrollUpUntilExists(app.staticTexts["Why Full Access?"]), "Full Access explanation not shown")
        XCTAssertTrue(scrollUpUntilExists(app.staticTexts["Where It Won’t Appear"]), "Availability note not shown")
    }
    #else
    func testKeyboardOnboardingIsHiddenWhenFeatureIsDisabled() {
        app.buttons["Settings"].tap()

        // Proving absence is the one place a long wait is pure cost.
        XCTAssertFalse(
            scrollUpUntilExists(app.buttons["keyboardSetupLink"], initialTimeout: 2, settleTimeout: 1),
            "keyboardSetupLink must not appear when the keyboard feature is disabled"
        )
    }
    #endif

    /// Waits for `element`, swiping up between attempts. The first wait covers a
    /// screen that is still laying out; the settle wait covers the scroll
    /// animation. Both return as soon as the element exists.
    private func scrollUpUntilExists(
        _ element: XCUIElement,
        initialTimeout: TimeInterval = 5,
        settleTimeout: TimeInterval = 2,
        maxSwipes: Int = 6
    ) -> Bool {
        if element.waitForExistence(timeout: initialTimeout) {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: settleTimeout) {
                return true
            }
        }
        return false
    }
}
