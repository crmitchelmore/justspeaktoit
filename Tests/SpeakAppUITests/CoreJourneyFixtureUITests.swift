import XCTest

final class CoreJourneyFixtureUITests: XCTestCase {
    func testFixtureProvidesNamedFocusedEditableTarget() {
        let fixture = XCUIApplication(bundleIdentifier: "com.justspeaktoit.core-journey-fixture")
        fixture.launch()
        defer { fixture.terminate() }

        let field = fixture.textViews["coreJourneyTargetField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("fixture accepts deterministic output")
        XCTAssertEqual(field.value as? String, "fixture accepts deterministic output")
        XCTAssertTrue(fixture.staticTexts["coreJourneyFixtureStatus"].exists)
    }
}
