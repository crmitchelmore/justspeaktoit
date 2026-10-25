import AppKit
import Security
import LocalAuthentication
import XCTest

/// Actual Settings controls, with the existing UUID-owned DEBUG bootstrap.
/// Alibaba validates configuration locally and has no balance HTTP transport.
final class SettingsCredentialUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyntheticAlibabaSettingsErrorRecoverySaveReplaceRelaunchAndRemove() throws {
        let identifier = UUID()
        let suite = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(suite)
        let app = XCUIApplication(bundleIdentifier: "com.justspeaktoit.mac")
        app.launchEnvironment["SPEAK_CORE_JOURNEY_PROFILE"] = identifier.uuidString
        app.launchEnvironment["SPEAK_CORE_JOURNEY_DIRECTORY"] = directory.path
        registerCleanup(app, suite: suite, directory: directory)

        // These two @AppStorage controls read .standard. Process arguments
        // shadow it without writing the real app's region/workspace settings.
        launch(app, region: "invalid-fixture-region")
        try openAlibaba(app)
        let field = app.secureTextFields["Alibaba Model Studio API Key"]
        XCTAssertFalse(app.buttons["Remove Key"].exists, "The UUID vault must start empty")
        field.click()
        field.typeText("synthetic-alibaba-first")
        app.buttons["Save Key"].click()
        try wait {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Set the Alibaba region"))
                .firstMatch.exists
        }
        XCTAssertFalse(app.buttons["Remove Key"].exists, "Rejected configuration must not save a credential")

        app.terminate()
        launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        XCTAssertFalse(app.buttons["Remove Key"].exists)
        try save(app, value: "synthetic-alibaba-first", replacing: false)
        try save(app, value: "synthetic-alibaba-replacement", replacing: true)

        app.terminate()
        launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        XCTAssertTrue(app.buttons["Replace Key"].waitForExistence(timeout: 15), "Startup must load the saved row")
        let remove = app.buttons["Remove Key"]
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        remove.click()
        let confirmation = app.dialogs.buttons["Remove Key"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.click()
        try wait { app.buttons["Save Key"].exists && !app.buttons["Remove Key"].exists }

        app.terminate()
        launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        XCTAssertTrue(app.buttons["Save Key"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Remove Key"].exists, "The deletion must survive startup")
    }

    @MainActor
    private func launch(_ app: XCUIApplication, region: String) {
        // Replace the whole argument list each time; invalid configuration
        // from the earlier process must not leak into the recovery launch.
        app.launchArguments = [
            "-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES",
            "-alibaba.newKey.region", region, "-alibaba.newKey.workspace", "synthetic-settings"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["toolbarRecordToggleButton"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func openAlibaba(_ app: XCUIApplication) throws {
        let navigation = app.descendants(matching: .any)["sidebarSettings-apiKeys"].firstMatch
        XCTAssertTrue(navigation.waitForExistence(timeout: 15))
        navigation.click()
        let search = app.textFields["Search API keys"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.click()
        search.typeText("Alibaba")
        try wait { app.staticTexts["Alibaba Model Studio (Transcription)"].exists }
        XCTAssertTrue(app.secureTextFields["Alibaba Model Studio API Key"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func save(_ app: XCUIApplication, value: String, replacing: Bool) throws {
        let field = app.secureTextFields["Alibaba Model Studio API Key"]
        field.click()
        field.typeText(value)
        let save = app.buttons[replacing ? "Replace Key" : "Save Key"]
        try wait { save.isEnabled }
        save.click()
        try wait { app.buttons["Replace Key"].exists && !app.buttons["Replace Key"].isEnabled }
        XCTAssertTrue(app.buttons["Remove Key"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Alibaba key, region and workspace saved")
        ).firstMatch.exists)
    }

    @MainActor
    private func wait(_ predicate: @escaping () -> Bool) throws {
        let result = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: 15
        )
        guard result == .completed else {
            XCTFail("The actual Settings control did not reach its expected state")
            throw SettingsTimeout()
        }
    }

    private struct SettingsTimeout: Error {}

    @MainActor
    private func registerCleanup(_ app: XCUIApplication, suite: String, directory: URL) {
        addTeardownBlock { @MainActor in
            if app.state != .notRunning { app.terminate() }
            // Stable and Alpha namespace the same UUID-owned fixture service.
            // Neither name can be the production vault or a legacy service.
            let authentication = LAContext()
            authentication.interactionNotAllowed = true
            for service in [suite, suite + ".alpha"] {
                let status = SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecUseAuthenticationContext as String: authentication
                ] as CFDictionary)
                XCTAssertTrue([errSecSuccess, errSecItemNotFound].contains(status), "Owned vault cleanup failed")
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
