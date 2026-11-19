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
    private var layout: [String: [Double]] = [:]

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
        app.launchArguments = [
            "-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES",
            "-diagnosticsConsent", "declined"
        ]
        // The workflow captures each website clip in light and dark appearance.
        let appearance = ProcessInfo.processInfo.environment["SITE_MEDIA_APPEARANCE"] ?? "light"
        app.launchEnvironment["SPEAK_CORE_JOURNEY_SITE_MEDIA_APPEARANCE"] = appearance
        if appearance == "dark" {
            app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
            fixture.launchArguments += ["-AppleInterfaceStyle", "Dark"]
            fixture.launchEnvironment["CORE_JOURNEY_TARGET_APPEARANCE"] = "dark"
        }
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
        record(layoutOf: app.windows.firstMatch, as: "app")
        try capturePage(app, sidebar: "sidebarDashboard", name: "mac-dashboard")
        try capturePage(app, sidebar: "sidebarHistory", name: "mac-history")
        // Feature clips: optional so a renamed page cannot block the core demo.
        for (sidebar, name, scrolls) in [
            ("sidebarSettings-transcription", "mac-transcription", false),
            ("sidebarSettings-postProcessing", "mac-post-processing", false),
            ("sidebarSettings-shortcuts", "mac-shortcuts", false),
            // Last: later sidebar items were not found after this page scrolled.
            ("sidebarCorrections", "mac-corrections", true)
        ] {
            captureOptionalPage(app, sidebar: sidebar, name: name, scrollsToList: scrolls)
        }
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
        record(layoutOf: fixture.windows.firstMatch, as: "fixture")
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
        mark("shown-\(name)")
    }

    @MainActor
    private func captureOptionalPage(
        _ app: XCUIApplication, sidebar: String, name: String, scrollsToList: Bool
    ) {
        let item = app.descendants(matching: .any)[sidebar].firstMatch
        guard item.waitForExistence(timeout: 5), item.isHittable else {
            mark("missing-\(name)")
            return
        }
        item.click()
        mark("show-\(name)")
        pause(3.5)
        save(app.windows.firstMatch.screenshot(), name: name)
        if scrollsToList {
            // Bring the saved list below the page header into view; a coordinate in the
            // detail pane needs no hit point on a particular scroll view.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6))
                .scroll(byDeltaX: 0, deltaY: -600)
            mark("scrolled-\(name)")
            pause(3.5)
            save(app.windows.firstMatch.screenshot(), name: "\(name)-list")
        }
        pause(2.5)
        mark("shown-\(name)")
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

    /// Window frames in screen points (top-left origin) so the renderer can crop
    /// the full-screen recording to the window at 1:1 instead of enlarging it.
    private func record(layoutOf window: XCUIElement, as name: String) {
        let frame = window.frame
        layout[name] = [frame.minX, frame.minY, frame.width, frame.height]
        if let screen = NSScreen.main?.frame {
            layout["screen"] = [0, 0, screen.width, screen.height]
        }
    }

    private func attachMarks() throws {
        let layoutData = try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted])
        let layoutAttachment = XCTAttachment(data: layoutData, uniformTypeIdentifier: "public.json")
        layoutAttachment.name = "layout.json"
        layoutAttachment.lifetime = .keepAlways
        add(layoutAttachment)
        let data = try JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "marks.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
