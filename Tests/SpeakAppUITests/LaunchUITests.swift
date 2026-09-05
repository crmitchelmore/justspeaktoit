import AppKit
import XCTest

/// Launched production bootstrap and focus survival, not a recording test.
final class LaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testProductionBootstrap_survivesFixtureFocusRoundTrip() throws {
        let identifier = UUID()
        let suiteName = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        let app = XCUIApplication()
        let fixture = XCUIApplication(bundleIdentifier: "com.justspeaktoit.core-journey-fixture")
        app.launchEnvironment["SPEAK_CORE_JOURNEY_PROFILE"] = identifier.uuidString
        // AppStorage reads these through UserDefaults' typed boolean accessor.
        // AppSettings' typed defaults are supplied by the DEBUG launch profile.
        app.launchArguments = ["-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES"]
        registerCleanup(app: app, fixture: fixture, suiteName: suiteName)

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        // This existing production control is built by MainView only after
        // WireUp has created and published the real AppEnvironment.
        let recordingControl = app.buttons["toolbarRecordToggleButton"]
        XCTAssertTrue(recordingControl.waitForExistence(timeout: 15), "Speak must finish production bootstrap")
        let originalProcess = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertEqual(originalProcess.bundleIdentifier, "com.justspeaktoit.mac")
        let originalPID = originalProcess.processIdentifier

        fixture.launch()
        let target = fixture.textViews["coreJourneyTargetField"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()
        target.typeText("bootstrap focus target")
        XCTAssertEqual(target.value as? String, "bootstrap focus target")
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 5),
            "Speak must remain alive while the target owns focus"
        )

        // Activate the captured process directly: a crash must never trigger a relaunch.
        XCTAssertFalse(originalProcess.isTerminated)
        XCTAssertTrue(originalProcess.activate(options: [.activateAllWindows]))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, originalPID)
        XCTAssertFalse(originalProcess.isTerminated)
        XCTAssertTrue(recordingControl.waitForExistence(timeout: 5))
        // Never click the recording control or send a recording hotkey.
    }

    private func registerCleanup(app: XCUIApplication, fixture: XCUIApplication, suiteName: String) {
        addTeardownBlock {
            for (application, name) in [(app, "Speak bootstrap"), (fixture, "Focus target")] {
                if application.state != .notRunning {
                    let screenshot = XCTAttachment(screenshot: application.screenshot())
                    screenshot.name = name
                    screenshot.lifetime = .keepAlways
                    self.add(screenshot)
                    application.terminate()
                }
            }
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
