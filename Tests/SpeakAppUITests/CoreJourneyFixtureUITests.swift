import XCTest

final class CoreJourneyFixtureUITests: XCTestCase {
    func testFixtureProvidesNamedEditableTarget_acceptsAndReadsBackText() {
        let fixture = XCUIApplication(bundleIdentifier: "com.justspeaktoit.core-journey-fixture")
        fixture.launch()
        addTeardownBlock {
            let screenshot = XCTAttachment(screenshot: fixture.screenshot())
            screenshot.name = "Core journey fixture final state"
            screenshot.lifetime = .keepAlways
            self.add(screenshot)
            fixture.terminate()
        }

        let field = fixture.textViews["coreJourneyTargetField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let focusedField = fixture.textViews.matching(
            NSPredicate(format: "hasKeyboardFocus == true")
        ).firstMatch
        XCTAssertEqual(focusedField.identifier, "coreJourneyTargetField")
        field.click()
        field.typeText("fixture accepts deterministic output")
        XCTAssertEqual(field.value as? String, "fixture accepts deterministic output")
        XCTAssertTrue(fixture.staticTexts["coreJourneyFixtureStatus"].exists)
    }
}
