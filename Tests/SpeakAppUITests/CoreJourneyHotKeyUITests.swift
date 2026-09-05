import AppKit
import XCTest

/// Native hotkey prerequisite for #802, not a capture-to-delivery journey.
final class CoreJourneyHotKeyUITests: XCTestCase {
    private struct Event: Decodable {
        let stage: String
        let source: String
        let frontmostBundleID: String?
    }

    private struct Snapshot: Decodable {
        let processID: Int32
        let registered: Bool
        let accessibilityTrusted: Bool
        let events: [Event]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testSupportedGlobalChord_reachesBackgroundSpeakThroughCarbonTwice() throws {
        let identifier = UUID()
        let suiteName = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let diagnosticsURL = directory.appendingPathComponent("hotkey-probe.json")
        let app = XCUIApplication(bundleIdentifier: "com.justspeaktoit.mac")
        let fixtureBundleID = "com.justspeaktoit.core-journey-fixture"
        let fixture = XCUIApplication(bundleIdentifier: fixtureBundleID)
        app.launchEnvironment["SPEAK_CORE_JOURNEY_PROFILE"] = identifier.uuidString
        app.launchEnvironment["SPEAK_CORE_JOURNEY_HOTKEY_PROBE"] = "1"
        app.launchArguments = ["-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES"]
        registerCleanup(app: app, fixture: fixture, suiteName: suiteName, directory: directory)

        app.launch()
        XCTAssertTrue(app.buttons["toolbarRecordToggleButton"].waitForExistence(timeout: 15))
        let process = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.justspeaktoit.mac"
        ).first)
        waitForSnapshot(at: diagnosticsURL, message: "Carbon hotkey registration must succeed") {
            $0.registered && $0.processID == process.processIdentifier && $0.events.isEmpty
        }

        fixture.launch()
        let target = fixture.textViews["coreJourneyTargetField"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()
        target.typeText("hotkey probe target")
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))

        for count in 1...2 {
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, fixtureBundleID)
            // XCTest synthesizes actual keyboard input in the foreground target.
            // Speak receives RegisterEventHotKey events while it is in background.
            fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
            waitForSnapshot(at: diagnosticsURL, message: "Global chord \(count) must reach background Speak") {
                $0.events.filter { $0.stage == "singleTap" }.count == count
            }
        }

        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: diagnosticsURL))
        XCTAssertEqual(snapshot.processID, process.processIdentifier)
        XCTAssertTrue(snapshot.registered)
        XCTAssertEqual(snapshot.events.map(\.stage), ["keyDown", "keyUp", "singleTap", "keyDown", "keyUp", "singleTap"])
        XCTAssertEqual(snapshot.events.filter { $0.stage == "singleTap" }.map(\.source), ["carbon", "carbon"])
        XCTAssertTrue(snapshot.events.allSatisfy { $0.frontmostBundleID == fixtureBundleID })
        XCTAssertFalse(process.isTerminated)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        XCTAssertEqual(target.value as? String, "hotkey probe target")
        let focusedField = fixture.textViews.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertEqual(focusedField.identifier, "coreJourneyTargetField")
    }

    private func waitForSnapshot(
        at url: URL,
        message: String,
        matches: @escaping (Snapshot) -> Bool
    ) {
        let ready = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
            return matches(snapshot)
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10)
        XCTAssertEqual(result, .completed, message)
    }

    private func registerCleanup(
        app: XCUIApplication,
        fixture: XCUIApplication,
        suiteName: String,
        directory: URL
    ) {
        addTeardownBlock {
            let diagnosticsURL = directory.appendingPathComponent("hotkey-probe.json")
            if let data = try? Data(contentsOf: diagnosticsURL) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Native hotkey stages and permission readiness"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
            for (application, name) in [(app, "Speak hotkey probe"), (fixture, "Global hotkey target")]
                where application.state != .notRunning {
                let screenshot = XCTAttachment(screenshot: application.screenshot())
                screenshot.name = name
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
                application.terminate()
            }
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
