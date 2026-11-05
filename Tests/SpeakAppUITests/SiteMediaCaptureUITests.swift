import AppKit
import XCTest

/// Captures website media from the real Debug app with fictional History and the
/// batch fixture (synthetic audio, fixed transcript). Skipped unless the
/// site-media workflow passes TEST_RUNNER_SITE_MEDIA_CAPTURE; not a qualification gate.
/// The sandboxed UI runner cannot write files, so screenshots and scene marks are kept
/// as named attachments that the workflow exports from the result bundle.
final class SiteMediaCaptureUITests: XCTestCase {
    private let fixtureBundleID = "com.justspeaktoit.core-journey-fixture"
    private let transcript = "Remind me to send the revised launch notes to the team before Friday."
    private var marks: [[String: Any]] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SITE_MEDIA_CAPTURE"] == "1" else {
            throw XCTSkip("Site media capture runs only from the site-media workflow")
        }
    }

    @MainActor
    func testCaptureSiteMedia() throws {
        let identifier = UUID()
        let suiteName = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(suiteName)
        let diagnosticsURL = directory.appendingPathComponent("hotkey-probe.json")
        let app = XCUIApplication(bundleIdentifier: "com.justspeaktoit.mac")
        let fixture = XCUIApplication(bundleIdentifier: fixtureBundleID)
        app.launchEnvironment["SPEAK_CORE_JOURNEY_PROFILE"] = identifier.uuidString
        app.launchEnvironment["SPEAK_CORE_JOURNEY_DIRECTORY"] = directory.path
        app.launchEnvironment["SPEAK_CORE_JOURNEY_BATCH"] = "1"
        app.launchEnvironment["SPEAK_CORE_JOURNEY_SITE_MEDIA"] = "1"
        app.launchArguments = ["-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES"]
        addTeardownBlock {
            XCTAssertNoThrow(try self.attachMarks())
            if fixture.state != .notRunning { fixture.terminate() }
            if app.state != .notRunning { app.terminate() }
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        app.launch()
        XCTAssertTrue(app.buttons["toolbarRecordToggleButton"].waitForExistence(timeout: 20))
        CoreJourneyGestureDriver.wait(at: diagnosticsURL, message: "Production hotkey must register") {
            $0.registered && $0.states == ["idle"]
        }
        mark("launched")
        try capturePage(app, sidebar: "sidebarDashboard", name: "mac-dashboard")
        try capturePage(app, sidebar: "sidebarHistory", name: "mac-history")
        mark("tour-finished")

        try dictate(app: app, fixture: fixture, diagnosticsURL: diagnosticsURL)
        mark("end")
    }

    @MainActor
    private func dictate(app: XCUIApplication, fixture: XCUIApplication, diagnosticsURL: URL) throws {
        fixture.launch()
        let target = fixture.textViews["coreJourneyTargetField"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()
        mark("editor-ready")
        target.typeText("Note to self: ")
        pause(1)
        try CoreJourneyGestureDriver.recordAndStop(
            fixture: fixture, diagnosticsURL: diagnosticsURL, terminalState: "completed"
        ) {
            mark("recording")
            pause(2)
            save(XCUIScreen.main.screenshot(), name: "mac-recording-screen")
            mark("recording-captured")
        }
        mark("completed")
        let copied = NSPredicate { _, _ in NSPasteboard.general.string(forType: .string) == self.transcript }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: copied, object: nil)], timeout: 10
        ), .completed, "The batch fixture transcript must reach the clipboard")
        pause(1.5)
        mark("paste")
        if (target.value as? String)?.hasSuffix(transcript) != true {
            target.typeKey("v", modifierFlags: .command)
        }
        let pasted = NSPredicate { _, _ in (target.value as? String)?.hasSuffix(self.transcript) == true }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: pasted, object: nil)], timeout: 5
        ), .completed)
        pause(3)
        save(XCUIScreen.main.screenshot(), name: "mac-delivered-screen")
        mark("delivered")

        app.activate()
        try capturePage(app, sidebar: "sidebarHistory", name: "mac-history-after")
        mark("history-after")
        pause(3)
    }

    @MainActor
    private func capturePage(_ app: XCUIApplication, sidebar: String, name: String) throws {
        let item = app.descendants(matching: .any)[sidebar].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), sidebar)
        item.click()
        mark("show-\(name)")
        pause(2.5)
        save(app.windows.firstMatch.screenshot(), name: name)
        pause(1.5)
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
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

    private func attachMarks() throws {
        let data = try JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "marks.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
