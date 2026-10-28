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
        try launch(app, region: "invalid-fixture-region")
        try openAlibaba(app)
        let field = app.secureTextFields["Alibaba Model Studio API Key"]
        XCTAssertFalse(app.buttons["Remove Key"].exists, "The UUID vault must start empty")
        field.click()
        field.typeText("synthetic-alibaba-first")
        app.buttons["Save Key"].click()
        try wait(app, stage: "Rejected configuration error is visible") {
            self.validationTextExists(app, containing: "Set the Alibaba region")
        }
        XCTAssertFalse(app.buttons["Remove Key"].exists, "Rejected configuration must not save a credential")

        app.terminate()
        try launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        XCTAssertFalse(app.buttons["Remove Key"].exists)
        try save(app, value: "synthetic-alibaba-first", replacing: false)
        try save(app, value: "synthetic-alibaba-replacement", replacing: true)

        app.terminate()
        try launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        try wait(app, stage: "Startup loads the saved row") { app.buttons["Replace Key"].exists }
        let remove = app.buttons["Remove Key"]
        try wait(app, stage: "Saved credential exposes Remove Key") { remove.exists }
        remove.click()
        let confirmationSheets = app.sheets.matching(NSPredicate(format: "label == %@", "alert"))
        let confirmationSheet = confirmationSheets.firstMatch
        let title = "Remove the Alibaba Model Studio (Transcription) key?"
        let confirmationTitle = confirmationSheet.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", title, title)
        ).firstMatch
        let confirmation = confirmationSheet.buttons["Remove Key"]
        try wait(app, stage: "Exact Alibaba removal sheet appears", timeout: 10) {
            confirmationSheets.count == 1 && confirmationTitle.exists && confirmation.exists
        }
        confirmation.click()
        try wait(app, stage: "Removed credential returns to the unsaved row") {
            app.buttons["Save Key"].exists && !app.buttons["Remove Key"].exists
        }

        app.terminate()
        try launch(app, region: "ap-southeast-1")
        try openAlibaba(app)
        try wait(app, stage: "Startup exposes the unsaved row") { app.buttons["Save Key"].exists }
        XCTAssertFalse(app.buttons["Remove Key"].exists, "The deletion must survive startup")
    }

    @MainActor
    private func launch(
        _ app: XCUIApplication, region: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // Replace the whole argument list each time; invalid configuration
        // from the earlier process must not leak into the recovery launch.
        app.launchArguments = [
            "-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES",
            "-alibaba.newKey.region", region, "-alibaba.newKey.workspace", "synthetic-settings"
        ]
        app.launch()
        try wait(app, stage: "Production bootstrap exposes recording control", file: file, line: line) {
            app.buttons["toolbarRecordToggleButton"].exists
        }
    }

    @MainActor
    private func openAlibaba(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let navigation = app.descendants(matching: .any)["sidebarSettings-apiKeys"].firstMatch
        try wait(app, stage: "Settings navigation is available", file: file, line: line) { navigation.exists }
        navigation.click()
        let search = app.textFields["Search API keys"]
        try wait(app, stage: "API key search is available", file: file, line: line) { search.exists }
        search.click()
        search.typeText("Alibaba")
        try revealAlibabaControls(app, file: file, line: line)
        try wait(app, stage: "Exact Alibaba provider row exists", file: file, line: line) {
            app.staticTexts["Alibaba Model Studio (Transcription)"].exists
        }
        try wait(app, stage: "Exact Alibaba secure field exists", file: file, line: line) {
            app.secureTextFields["Alibaba Model Studio API Key"].exists
        }
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
            try failSettings(app, stage: "Expected one Settings pane containing Search; found \(panes.count)",
                           file: file, line: line)
        }
        let pane = panes[0]
        // Spend the original reveal bound scrolling, rather than repeatedly
        // hit-testing controls that are still outside the pane. Geometry only
        // admits the final full usability check; it cannot satisfy that check.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        for _ in 0..<8 {
            if alibabaControlsFitViewport(app, pane: pane) { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            pane.scroll(byDeltaX: 0, deltaY: -300)
        }
        guard alibabaControlsAreHittable(app) else {
            try failSettings(app, stage: "Alibaba row, secure field and credential actions were not revealed",
                           file: file, line: line)
        }
    }

    @MainActor
    private func alibabaControlsFitViewport(_ app: XCUIApplication, pane: XCUIElement) -> Bool {
        let field = app.secureTextFields["Alibaba Model Studio API Key"]
        guard field.exists else { return false }
        let action = app.buttons[app.buttons["Replace Key"].exists ? "Replace Key" : "Save Key"]
        guard action.exists else { return false }
        let viewport = pane.frame
        let fieldFrame = field.frame
        let actionFrame = action.frame
        guard [viewport, fieldFrame, actionFrame].allSatisfy({ frame in
            !frame.isEmpty && frame.minX.isFinite && frame.minY.isFinite
                && frame.maxX.isFinite && frame.maxY.isFinite
        }) else { return false }
        return viewport.contains(fieldFrame) && viewport.contains(actionFrame)
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
    private func failSettings(
        _ app: XCUIApplication, stage: String, file: StaticString, line: UInt
    ) throws -> Never {
        if app.state != .notRunning {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Alibaba Settings: " + stage
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
    private func save(
        _ app: XCUIApplication, value: String, replacing: Bool, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let field = app.secureTextFields["Alibaba Model Studio API Key"]
        field.click()
        field.typeText(value)
        let save = app.buttons[replacing ? "Replace Key" : "Save Key"]
        try wait(app, stage: "Credential save action is enabled", file: file, line: line) { save.isEnabled }
        save.click()
        try wait(app, stage: "Saved credential exposes disabled Replace Key", file: file, line: line) {
            app.buttons["Replace Key"].exists && !app.buttons["Replace Key"].isEnabled
        }
        XCTAssertTrue(app.buttons["Remove Key"].exists)
        XCTAssertTrue(validationTextExists(app, containing: "Alibaba key, region and workspace saved"),
                      file: file, line: line)
    }

    @MainActor
    private func validationTextExists(_ app: XCUIApplication, containing text: String) -> Bool {
        // Accept the rendered validation copy in either AX label or value.
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch.exists
    }

    @MainActor
    private func wait(
        _ app: XCUIApplication, stage: String, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping () -> Bool
    ) throws {
        let result = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)],
            timeout: timeout
        )
        guard result == .completed else {
            try failSettings(app, stage: stage, file: file, line: line)
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
