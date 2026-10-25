import AppKit
import Security
import LocalAuthentication
import XCTest

/// Actual Settings controls, with the existing UUID-owned DEBUG bootstrap.
/// Alibaba validates configuration locally and has no balance HTTP transport.
final class SettingsCredentialUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !DEBUG
        throw XCTSkip("Credential UI qualification requires the DEBUG-only UUID CoreJourney bootstrap")
        #endif
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
    private func openAlibaba(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let navigation = app.descendants(matching: .any)["sidebarSettings-apiKeys"].firstMatch
        XCTAssertTrue(navigation.waitForExistence(timeout: 15))
        navigation.click()
        let search = app.textFields["Search API keys"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.click()
        search.typeText("Alibaba")
        try revealAlibabaControls(app, file: file, line: line)
        try wait { app.staticTexts["Alibaba Model Studio (Transcription)"].exists }
        XCTAssertTrue(app.secureTextFields["Alibaba Model Studio API Key"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func revealAlibabaControls(
        _ app: XCUIApplication, file: StaticString, line: UInt
    ) throws {
        // Bind the actual pane while Search is visible. A query re-evaluated
        // against Search would stop finding it once the lazy stack scrolls away.
        let panes = app.scrollViews.containing(.textField, identifier: "Search API keys")
            .allElementsBoundByAccessibilityElement
        guard panes.count == 1 else {
            try failReveal(app, stage: "Expected one Settings pane containing Search; found \(panes.count)",
                           file: file, line: line)
        }
        let pane = panes[0]
        // Reuse the original 15-second row-readiness bound. Eight 300-pixel
        // scrolls cover the configuration/storage cards above the filtered row
        // on the observed 1024x768 host without changing density or window size.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        for _ in 0..<8 {
            if alibabaControlsAreHittable(app) { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            pane.scroll(byDeltaX: 0, deltaY: -300)
        }
        guard alibabaControlsAreHittable(app) else {
            try failReveal(app, stage: "Alibaba row, secure field and credential actions were not revealed",
                           file: file, line: line)
        }
    }

    @MainActor
    private func alibabaControlsAreHittable(_ app: XCUIApplication) -> Bool {
        let field = app.secureTextFields["Alibaba Model Studio API Key"]
        let action = app.buttons[app.buttons["Replace Key"].exists ? "Replace Key" : "Save Key"]
        let remove = app.buttons["Remove Key"]
        return app.staticTexts["Alibaba Model Studio (Transcription)"].exists
            && field.exists && field.isHittable && action.exists && action.isHittable
            && (!remove.exists || remove.isHittable)
    }

    @MainActor
    private func failReveal(
        _ app: XCUIApplication, stage: String, file: StaticString, line: UInt
    ) throws -> Never {
        if app.state != .notRunning {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Alibaba Settings reveal: " + stage
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Owned Settings accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTFail(stage, file: file, line: line)
        throw SettingsTimeout()
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
