import AppKit
import XCTest

/// Full production batch orchestration through clipboard delivery. Native paste
/// is additionally required when the launched process genuinely has posting access.
final class CoreJourneyBatchUITests: XCTestCase {
    private let fixtureBundleID = "com.justspeaktoit.core-journey-fixture"
    private let transcript = "A complete batch journey, through the clipboard."
    private let initialField = "Target: "
    private let initialClipboard = "core journey clipboard before recording"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testBatchPostProcessingOff_globalHotkeyDeliversClipboardAndDurableHistory() throws {
        let identifier = UUID()
        let suiteName = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(suiteName)
        let diagnosticsURL = directory.appendingPathComponent("hotkey-probe.json")
        let app = XCUIApplication(bundleIdentifier: "com.justspeaktoit.mac")
        let fixture = XCUIApplication(bundleIdentifier: fixtureBundleID)
        app.launchEnvironment["SPEAK_CORE_JOURNEY_PROFILE"] = identifier.uuidString
        app.launchEnvironment["SPEAK_CORE_JOURNEY_DIRECTORY"] = directory.path
        app.launchEnvironment["SPEAK_CORE_JOURNEY_BATCH"] = "1"
        app.launchArguments = ["-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES"]
        registerCleanup(app: app, fixture: fixture, suiteName: suiteName, directory: directory)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(initialClipboard, forType: .string))

        app.launch()
        XCTAssertTrue(app.buttons["toolbarRecordToggleButton"].waitForExistence(timeout: 15))
        let process = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.justspeaktoit.mac"
        ).first)
        waitForSnapshot(at: diagnosticsURL, message: "Production hotkey must register") {
            $0.registered && $0.processID == process.processIdentifier && $0.states == ["idle"]
        }
        fixture.launch()
        let target = fixture.textViews["coreJourneyTargetField"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()
        target.typeText(initialField)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        try driveRecording(fixture: fixture, target: target, diagnosticsURL: diagnosticsURL)
        try assertDelivery(directory: directory, target: target, process: process, fixture: fixture)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
    }

    @MainActor
    private func driveRecording(fixture: XCUIApplication, target: XCUIElement, diagnosticsURL: URL) throws {
        // A supported global chord enters through Carbon, never MainManager callbacks.
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        waitForSnapshot(at: diagnosticsURL, message: "Double-tap must start production recording") {
            $0.states.last == "recording"
        }
        XCTAssertEqual(target.value as? String, initialField)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), initialClipboard)
        // Wait out the configured four-second double-tap window so the stop is
        // a distinct single tap. This is a gesture timing assertion, not a retry.
        waitForSnapshot(at: diagnosticsURL, message: "Recording must survive until the stop gesture") {
            guard let lastEvent = $0.events.last else { return false }
            return $0.states.last == "recording"
                && ProcessInfo.processInfo.systemUptime - lastEvent.uptime > 4.2
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, fixtureBundleID)
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        waitForSnapshot(at: diagnosticsURL, message: "Stop must run transcription, delivery, and History") {
            $0.states.last == "completed"
        }
    }

    @MainActor
    private func assertDelivery(
        directory: URL, target: XCUIElement, process: NSRunningApplication, fixture: XCUIApplication
    ) throws {
        let snapshot = try JSONDecoder().decode(
            BatchSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("hotkey-probe.json"))
        )
        XCTAssertEqual(snapshot.processID, process.processIdentifier)
        XCTAssertFalse(process.isTerminated)
        XCTAssertEqual(snapshot.states, ["idle", "recording", "processing", "delivering", "completed"])
        XCTAssertEqual(snapshot.events.filter { $0.source == "carbon" }.map(\.stage), ["doubleTap", "singleTap"])
        XCTAssertEqual(snapshot.events.filter { $0.stage == "keyDown" }.count, 3)
        XCTAssertEqual(snapshot.events.filter { $0.stage == "keyUp" }.count, 3)
        XCTAssertTrue(snapshot.events.allSatisfy { $0.frontmostBundleID == fixtureBundleID })
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), transcript)
        let expectedField = snapshot.eventPostingAllowed ? initialField + transcript : initialField
        let valueMatches = NSPredicate { _, _ in target.value as? String == expectedField }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: valueMatches, object: nil)], timeout: 5
        ), .completed, "Native target must match the actual event-posting permission branch")
        let focused = fixture.textViews.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertEqual(focused.identifier, "coreJourneyTargetField")
        let evidence = XCTAttachment(string: snapshot.eventPostingAllowed
            ? "Native PID-directed paste verified. Direct AX insertion and physical microphone remain untested."
            : "No OS event-posting grant: clipboard and History verified; native editor insertion remains untested.")
        evidence.name = "Actual native delivery coverage"
        evidence.lifetime = .keepAlways
        add(evidence)
        try assertHTTPAndHistory(directory: directory)
    }

    @MainActor
    private func assertHTTPAndHistory(directory: URL) throws {
        let http = try JSONDecoder().decode(
            BatchHTTPResult.self, from: Data(contentsOf: directory.appendingPathComponent("batch-http.json"))
        )
        XCTAssertEqual(http.acceptedRequests, 1, "One request must contain the exact captured WAV bytes and model")
        XCTAssertEqual(http.rejectedRequests, 0, "No unexpected provider or post-processing request is permitted")
        let historyURL = directory.appendingPathComponent("SpeakApp/History/history-log.json")
        let persisted = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: historyURL),
                  let items = try? JSONDecoder().decode([BatchHistoryRecord].self, from: data) else { return false }
            return items.count == 1
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: persisted, object: nil)], timeout: 10
        ), .completed, "One History item must be persisted by the real HistoryManager")
        let items = try JSONDecoder().decode([BatchHistoryRecord].self, from: Data(contentsOf: historyURL))
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.rawTranscription, transcript)
        XCTAssertNil(item.postProcessedTranscription)
        XCTAssertEqual(item.recordingDuration, 0.25, accuracy: 0.001)
        XCTAssertEqual(item.trigger.gesture, "doubleTap")
        XCTAssertEqual(item.trigger.outputMethod, "clipboard")
        let fixtureName = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureBundleID)
            .first?.localizedName
        XCTAssertNotNil(fixtureName)
        XCTAssertEqual(item.trigger.destinationApplication, fixtureName)
        XCTAssertEqual(item.modelUsages.map(\.phase), ["batch"])
        XCTAssertEqual(item.modelUsages.map(\.modelIdentifier), ["core-journey/batch-fixture"])
        // The start-timeline diagnostic may also carry recordingStarted. Check
        // semantic order without pinning the number of diagnostic-only entries.
        let phases = item.events.map(\.kind).reduce(into: [String]()) { result, kind in
            if result.last != kind { result.append(kind) }
        }
        XCTAssertEqual(phases, ["recordingStarted", "recordingStopped", "transcriptionReceived", "outputDelivered"])
        for kind in ["recordingStopped", "transcriptionReceived", "outputDelivered"] {
            XCTAssertEqual(item.events.filter { $0.kind == kind }.count, 1, kind)
        }
        XCTAssertTrue(item.errors.isEmpty)
        let audioURL = try XCTUnwrap(item.audioFileURL)
        let recordingsPath = directory.appendingPathComponent("Recordings").resolvingSymlinksInPath().path
        XCTAssertTrue(audioURL.resolvingSymlinksInPath().path.hasPrefix(recordingsPath + "/"))
        XCTAssertEqual(try Data(contentsOf: audioURL).count, 8_044)
    }

    private func waitForSnapshot(at url: URL, message: String, matches: @escaping (BatchSnapshot) -> Bool) {
        let ready = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(BatchSnapshot.self, from: data) else { return false }
            return matches(snapshot)
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15
        ), .completed, message)
    }

    private func registerCleanup(app: XCUIApplication, fixture: XCUIApplication, suiteName: String, directory: URL) {
        let previousClipboard: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        // Select XCTest's synchronous overload before type-checking the body.
        let cleanup: () throws -> Void = {
            self.attachDiagnostics(in: directory)
            self.terminateWithScreenshot(app)
            self.terminateWithScreenshot(fixture)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(previousClipboard)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        addTeardownBlock(cleanup)
    }

    private func attachDiagnostics(in directory: URL) {
        let paths = ["hotkey-probe.json", "batch-http.json", "SpeakApp/History/history-log.json"]
        for path in paths {
            let url = directory.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = path
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func terminateWithScreenshot(_ application: XCUIApplication) {
        guard application.state != .notRunning else { return }
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        application.terminate()
    }
}

private struct BatchSnapshot: Decodable {
    struct Event: Decodable {
        let stage: String
        let source: String
        let frontmostBundleID: String?
        let uptime: TimeInterval
    }
    let processID: Int32
    let registered: Bool
    let accessibilityTrusted: Bool
    let eventPostingAllowed: Bool
    let states: [String]
    let events: [Event]
}

private struct BatchHTTPResult: Decodable {
    let acceptedRequests: Int
    let rejectedRequests: Int
}

private struct BatchHistoryRecord: Decodable {
    struct Trigger: Decodable {
        let gesture: String
        let outputMethod: String
        let destinationApplication: String?
    }
    struct Usage: Decodable {
        let phase: String
        let modelIdentifier: String
    }
    struct Event: Decodable { let kind: String }
    struct ErrorRecord: Decodable { let message: String }
    let rawTranscription: String?
    let postProcessedTranscription: String?
    let recordingDuration: TimeInterval
    let audioFileURL: URL?
    let trigger: Trigger
    let modelUsages: [Usage]
    let events: [Event]
    let errors: [ErrorRecord]
}
