import XCTest

/// Run by the existing CI bundle on its newly created, job-owned Simulator.
/// Synthetic Alibaba configuration is local-only; never use a real device/vault.
final class SettingsCredentialUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This credential qualification requires a fresh owned Simulator")
        #endif
        // xcodebuild's documented TEST_RUNNER_ propagation supplies this only
        // after CI creates a fresh owned device. Refuse manual/personal targets
        // before constructing or launching the app (and therefore its vault).
        let environment = ProcessInfo.processInfo.environment
        guard let marker = environment["JSTI_OWNED_SETTINGS_TARGET"]?.data(using: .utf8),
              let target = try? JSONDecoder().decode(OwnedSettingsTarget.self, from: marker),
              target.version == 1,
              target.owner.split(separator: ":", omittingEmptySubsequences: false).count == 3,
              !target.owner.contains(where: { $0.isWhitespace }),
              target.owner.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              target.runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime."),
              target.deviceType.hasPrefix("com.apple.CoreSimulator.SimDeviceType."),
              let ownedID = UUID(uuidString: target.createdUUID),
              let actual = environment["SIMULATOR_UDID"].flatMap({ UUID(uuidString: $0) }),
              ownedID == actual else {
            throw XCTSkip("Credential UI qualification requires the matching fresh job-owned Simulator receipt")
        }
        continueAfterFailure = false
    }

    func testSyntheticAlibabaSettingsErrorRecoverySaveReplaceRelaunchAndRemove() throws {
        let app = XCUIApplication()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        try launch(app, region: "invalid-fixture-region")
        try openAlibaba(app)
        XCTAssertFalse(app.buttons["Clear Stored Key"].exists, "The fresh Simulator must have no Alibaba key")
        try save(app, value: "synthetic-alibaba-first", success: false)
        XCTAssertFalse(app.buttons["Clear Stored Key"].exists)

        app.terminate()
        try launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        try save(app, value: "synthetic-alibaba-first", success: true)
        try save(app, value: "synthetic-alibaba-replacement", success: true)

        app.terminate()
        try launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        let clear = app.buttons["Clear Stored Key"]
        XCTAssertTrue(clear.waitForExistence(timeout: 15), "Startup must load the saved row")
        try reveal(clear, in: app)
        clear.tap()
        try wait { !app.buttons["Clear Stored Key"].exists }

        app.terminate()
        try launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        XCTAssertFalse(app.buttons["Clear Stored Key"].exists, "The deletion must survive startup")
        XCTAssertTrue(app.staticTexts["Missing"].exists)
    }

    private func launch(_ app: XCUIApplication, region: String) throws {
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "-visualDensity", "normal",
            "-alibaba.newKey.region", region, "-alibaba.newKey.workspace", "synthetic-settings"
        ]
        app.launch()
        try app.skipFirstRunForUITest(ready: app.buttons["settingsNavLink"])
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
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Alibaba")
        let save = app.buttons["apiKeysSaveButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        try wait { save.isHittable && save.isEnabled }
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

    private struct OwnedSettingsTarget: Decodable {
        let version: Int
        let owner: String
        let createdUUID: String
        let runtime: String
        let deviceType: String
    }

    private struct SettingsTimeout: Error {}
}
