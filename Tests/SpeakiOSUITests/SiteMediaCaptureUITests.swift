import XCTest

/// Drives the real iPhone app on the Simulator and saves full-screen screenshots for
/// the website clips. The deterministic `JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT`
/// hook stands in for the microphone and transcriber, so the text is fictional
/// and fixed. Skipped unless the workflow passes TEST_RUNNER_SITE_MEDIA_CAPTURE;
/// not a qualification gate. Screenshots are attachments the workflow exports.
final class SiteMediaCaptureUITests: XCTestCase {
    private static let transcript =
        "Pick up oat milk and lemons on the way home, and move the team lunch to Thursday."
    private static let elementTimeout: TimeInterval = 15
    private var app: XCUIApplication!
    private var marks: [[String: Any]] = []

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Site media capture runs only on the Simulator")
        #endif
        guard ProcessInfo.processInfo.environment["SITE_MEDIA_CAPTURE"] == "1" else {
            throw XCTSkip("Site media capture runs only from the site-media workflow")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launchEnvironment["JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT"] = Self.transcript
    }

    func testCaptureSiteMedia() throws {
        addTeardownBlock { self.attachMarks() }
        app.launch()
        let record = app.buttons["recordToggleButton"]
        try app.skipFirstRunForUITest(ready: record)
        // A one-time notice would otherwise cover the transcript in every frame.
        let notice = app.buttons["Got it"]
        if notice.waitForExistence(timeout: 3) {
            notice.tap()
        }
        mark("ready")
        pause(2.5)
        save("ios-ready")

        record.tap()
        mark("recording")
        XCTAssertTrue(app.staticTexts[Self.transcript].waitForExistence(timeout: Self.elementTimeout))
        pause(3)
        save("ios-recording")
        record.tap()
        XCTAssertTrue(app.buttons["copyTranscriptButton"].waitForExistence(timeout: Self.elementTimeout))
        mark("stopped")
        pause(2)
        app.buttons["copyTranscriptButton"].tap()
        mark("copied")
        pause(2.5)
        save("ios-transcript")
        showHistory()
        showSettings()
        mark("end")
    }

    private func showHistory() {
        let history = app.buttons["historyNavLink"]
        if history.waitForExistence(timeout: 5) {
            history.tap()
            mark("history")
            pause(3.5)
            save("ios-history")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            pause(1)
        }
    }

    private func showSettings() {
        let settings = app.buttons["settingsNavLink"]
        XCTAssertTrue(settings.waitForExistence(timeout: Self.elementTimeout))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: Self.elementTimeout))
        mark("settings")
        pause(2)
        save("ios-settings")
        openSettingsPage("transcription")
        if scrollUpUntilExists(app.segmentedControls["transcriptionLocationPicker"]) {
            mark("models")
            pause(3)
            save("ios-models")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSettingsPage("recording")
        let trigger = app.buttons["hardwareTriggerSettingsLink"]
        if scrollUpUntilExists(trigger) {
            trigger.tap()
            XCTAssertTrue(
                app.navigationBars["Action Button & Shortcuts"].waitForExistence(timeout: Self.elementTimeout)
            )
            mark("action-button")
            pause(4)
            save("ios-action-button")
        }
    }

    private func openSettingsPage(_ page: String) {
        let link = app.buttons["settingsPage.\(page)"]
        if scrollUpUntilExists(link) { link.tap() }
    }

    private func scrollUpUntilExists(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func mark(_ name: String) {
        marks.append(["name": name, "time": Date().timeIntervalSince1970])
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "hold frame")], timeout: seconds)
    }

    private func attachMarks() {
        guard let data = try? JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted]) else {
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "marks.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
