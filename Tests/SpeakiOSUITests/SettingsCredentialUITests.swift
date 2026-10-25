import XCTest

/// Run by the existing CI bundle on its newly created, job-owned Simulator.
/// Synthetic Alibaba configuration is local-only; never use a real device/vault.
final class SettingsCredentialUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This credential qualification requires a fresh owned Simulator")
        #endif
        continueAfterFailure = false
    }

    func testSyntheticAlibabaSettingsErrorRecoverySaveReplaceRelaunchAndRemove() throws {
        let app = XCUIApplication()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        launch(app, region: "invalid-fixture-region")
        try openAlibaba(app)
        XCTAssertFalse(app.buttons["Clear Stored Key"].exists, "The fresh Simulator must have no Alibaba key")
        try save(app, value: "synthetic-alibaba-first", success: false)
        XCTAssertFalse(app.buttons["Clear Stored Key"].exists)

        app.terminate()
        launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        try save(app, value: "synthetic-alibaba-first", success: true)
        try save(app, value: "synthetic-alibaba-replacement", success: true)

        app.terminate()
        launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        let clear = app.buttons["Clear Stored Key"]
        XCTAssertTrue(clear.waitForExistence(timeout: 15), "Startup must load the saved row")
        try reveal(clear, in: app)
        clear.tap()
        try wait { !app.buttons["Clear Stored Key"].exists }

        app.terminate()
        launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        XCTAssertFalse(app.buttons["Clear Stored Key"].exists, "The deletion must survive startup")
        XCTAssertTrue(app.staticTexts["Missing"].exists)
    }

    private func launch(_ app: XCUIApplication, region: String) {
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "-visualDensity", "normal",
            "-alibaba.newKey.region", region, "-alibaba.newKey.workspace", "synthetic-settings"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["settingsNavLink"].waitForExistence(timeout: 60))
    }

    private func openAlibaba(_ app: XCUIApplication) throws {
        app.buttons["settingsNavLink"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let manage = app.buttons["Manage Keys"]
        try reveal(manage, in: app)
        manage.tap()
        XCTAssertTrue(app.navigationBars["API Keys"].waitForExistence(timeout: 15))
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("Alibaba")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        XCTAssertTrue(app.staticTexts["Alibaba Model Studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.secureTextFields["API Key"].waitForExistence(timeout: 15))
    }

    private func save(_ app: XCUIApplication, value: String, success: Bool) throws {
        let field = app.secureTextFields["API Key"]
        try reveal(field, in: app)
        field.tap()
        field.typeText(value)
        let save = app.navigationBars.buttons["Save"]
        try wait { save.isEnabled }
        save.tap()
        let alert = app.alerts["Validation"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        let message = success ? "Alibaba key, region and workspace saved" : "Set the Alibaba region"
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch.exists)
        alert.buttons["OK"].tap()
        if success { XCTAssertTrue(app.buttons["Clear Stored Key"].waitForExistence(timeout: 15)) }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        guard element.exists && element.isHittable else {
            XCTFail("The actual Settings control was not reachable")
            throw SettingsTimeout()
        }
    }

    private func wait(_ predicate: @escaping () -> Bool) throws {
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() }, object: nil
        )], timeout: 15) == .completed else {
            XCTFail("The actual Settings control did not reach its expected state")
            throw SettingsTimeout()
        }
    }

    private struct SettingsTimeout: Error {}
}
