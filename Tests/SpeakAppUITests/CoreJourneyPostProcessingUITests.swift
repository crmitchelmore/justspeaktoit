import AppKit
import SpeakCore
import XCTest

final class CoreJourneyPostProcessingUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        self.continueAfterFailure = false
    }

    @MainActor
    func testBatchPolishing_DeliversProcessedTextAndRetainsRawHistory() throws {
        let journey = try PolishJourney(self, scenario: "batchPolishSuccess")
        try journey.record(terminal: "completed", previousClipboard: journey.initialClipboard)
        try journey.assertDelivery(text: "First synthetic words, cleaned.", runs: 1)
        try journey.assertHTTP(["batchA", "polishA"])
        let rows = try journey.history(count: 1)
        try journey.assertRow(rows[0], raw: "first synthetic words for cleanup",
                              processed: "First synthetic words, cleaned.", failed: false)
        try journey.assertGestures(runs: 1, terminalStates: ["completed"])
    }

    @MainActor
    func testBatchPolishing_FailureThenFreshRecordingRecoversInSameProcess() throws {
        let journey = try PolishJourney(self, scenario: "batchPolishFailureThenSuccess")
        try journey.record(terminal: "failed", previousClipboard: journey.initialClipboard)
        journey.assertVisibleFailure()
        try journey.assertDelivery(text: "first synthetic words for cleanup", runs: 1)
        try journey.assertHTTP(["batchA", "polishA"])
        let original = try XCTUnwrap(journey.history(count: 1).first)
        let originalObject = try journey.storedObject(id: original.id)
        try journey.assertRow(original, raw: "first synthetic words for cleanup", processed: nil, failed: true)
        try journey.assertGestures(runs: 1, terminalStates: ["failed"])

        // The second gesture uses the same running application and existing History.
        try journey.record(terminal: "completed", previousClipboard: "first synthetic words for cleanup")
        try journey.assertDelivery(text: "Second synthetic words, cleaned.", runs: 2)
        try journey.assertHTTP(["batchA", "polishA", "batchB", "polishB"])
        let rows = try journey.history(count: 2)
        XCTAssertEqual(rows.filter { $0.id == original.id }, [original], "Recovery must not rewrite the failure row")
        XCTAssertEqual(try journey.storedObject(id: original.id), originalObject,
                       "Every persisted field of the failed row must survive the next recording")
        let recovered = try XCTUnwrap(rows.first { $0.id != original.id })
        try journey.assertRow(recovered, raw: "second synthetic words for cleanup",
                              processed: "Second synthetic words, cleaned.", failed: false)
        try journey.assertGestures(runs: 2, terminalStates: ["failed", "completed"])
    }
}

@MainActor
private final class PolishJourney {
    let initialClipboard = "core journey clipboard before polishing"
    private let initialField = "Target: "
    private let fixtureID = "com.justspeaktoit.core-journey-fixture"
    private let app = XCUIApplication(bundleIdentifier: "com.justspeaktoit.mac")
    private let fixture = XCUIApplication(bundleIdentifier: "com.justspeaktoit.core-journey-fixture")
    private let directory: URL
    private let diagnostics: URL
    private let owner: XCTestCase
    private var process: NSRunningApplication?
    private var delivered: [String] = []
    private var target: XCUIElement { self.fixture.textViews["coreJourneyTargetField"] }

    init(_ owner: XCTestCase, scenario: String) throws {
        self.owner = owner
        let identifier = UUID()
        let suite = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        self.directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(suite)
        self.diagnostics = self.directory.appendingPathComponent("hotkey-probe.json")
        self.app.launchEnvironment["SPEAK_CORE_JOURNEY_PROFILE"] = identifier.uuidString
        self.app.launchEnvironment["SPEAK_CORE_JOURNEY_DIRECTORY"] = self.directory.path
        self.app.launchEnvironment["SPEAK_CORE_JOURNEY_SCENARIO"] = scenario
        self.app.launchArguments = ["-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES"]
        self.registerCleanup(suite: suite)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(self.initialClipboard, forType: .string))
        self.app.launch()
        XCTAssertTrue(self.app.buttons["toolbarRecordToggleButton"].waitForExistence(timeout: 15))
        CoreJourneyGestureDriver.wait(at: self.diagnostics, message: "Production hotkey must register") {
            $0.registered && $0.states == ["idle"]
        }
        self.process = try XCTUnwrap(NSRunningApplication(processIdentifier:
            CoreJourneyGestureDriver.snapshot(at: self.diagnostics).processID))
        XCTAssertEqual(self.process?.bundleIdentifier, "com.justspeaktoit.mac")
        self.fixture.launch()
        XCTAssertTrue(self.target.waitForExistence(timeout: 10))
        self.target.click()
        self.target.typeText(self.initialField)
        XCTAssertTrue(self.app.wait(for: .runningBackground, timeout: 5))
    }

    func record(terminal: String, previousClipboard: String) throws {
        let fieldBefore = self.target.value as? String
        try CoreJourneyGestureDriver.recordAndStop(
            fixture: self.fixture, diagnosticsURL: self.diagnostics, terminalState: terminal
        ) {
            XCTAssertEqual(self.target.value as? String, fieldBefore)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), previousClipboard)
        }
    }

    func assertDelivery(text: String, runs: Int) throws {
        self.delivered.append(text)
        XCTAssertEqual(self.delivered.count, runs)
        let snapshot = try CoreJourneyGestureDriver.snapshot(at: self.diagnostics)
        XCTAssertEqual(snapshot.processID, self.process?.processIdentifier)
        XCTAssertFalse(try XCTUnwrap(self.process).isTerminated)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
        let expected = snapshot.eventPostingAllowed ? self.initialField + self.delivered.joined() : self.initialField
        let ready = NSPredicate { _, _ in self.target.value as? String == expected }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5),
                       .completed, "Field contents must follow actual OS event-posting permission")
        XCTAssertEqual(self.fixture.textViews.matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch.identifier, "coreJourneyTargetField")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, self.fixtureID)
        let coverage = XCTAttachment(string: snapshot.eventPostingAllowed
            ? "Native PID-directed paste observed; physical microphone and direct AX insertion untested."
            : "Clipboard/History observed; OS event posting unavailable, native editor insertion untested.")
        coverage.name = "Actual polishing delivery coverage"
        coverage.lifetime = .keepAlways
        self.owner.add(coverage)
    }

    func assertVisibleFailure() {
        let headline = self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Post-processing failed"))
        XCTAssertTrue(headline.firstMatch.waitForExistence(timeout: 3), "The real production HUD must show failure")
        let retry = self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "⌘R"))
        XCTAssertTrue(retry.firstMatch.exists, "The real production HUD must expose retry guidance")
        XCTAssertTrue(self.app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Synthetic post-processing rejection"
        )).firstMatch.exists, "The actual controlled rejection must be visible")
        let attachment = XCTAttachment(screenshot: self.app.screenshot())
        attachment.name = "Visible production post-processing failure and retry"
        attachment.lifetime = .keepAlways
        self.owner.add(attachment)
    }

    func assertHTTP(_ expected: [String]) throws {
        struct HTTP: Decodable {
            let acceptedRequests: Int
            let rejectedRequests: Int
            let sequence: [String]
        }
        let result = try JSONDecoder().decode(HTTP.self, from: Data(contentsOf:
            self.directory.appendingPathComponent("batch-http.json")))
        XCTAssertEqual(result.sequence, expected)
        XCTAssertEqual(result.acceptedRequests, expected.count)
        XCTAssertEqual(result.rejectedRequests, 0)
    }

    func history(count: Int) throws -> [PolishHistoryRow] {
        let path = self.directory.appendingPathComponent("SpeakApp/History/history-log.json")
        let flushed = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: path),
                  let rows = try? JSONDecoder().decode([PolishHistoryRow].self, from: data) else { return false }
            return rows.count == count
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: flushed, object: nil)], timeout: 10),
                       .completed, "The real HistoryManager must durably flush exactly the admitted rows")
        return try JSONDecoder().decode([PolishHistoryRow].self, from: Data(contentsOf: path))
    }

    func storedObject(id: UUID) throws -> NSDictionary {
        let path = self.directory.appendingPathComponent("SpeakApp/History/history-log.json")
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]])
        let row = try XCTUnwrap(objects.first { ($0["id"] as? String)?.lowercased() == id.uuidString.lowercased() })
        return row as NSDictionary
    }

    func assertRow(_ row: PolishHistoryRow, raw: String, processed: String?, failed: Bool) throws {
        XCTAssertEqual(row.rawTranscription, raw)
        XCTAssertEqual(row.postProcessedTranscription, processed)
        XCTAssertEqual(row.recordingDuration, 0.25, accuracy: 0.001)
        XCTAssertEqual(row.trigger.gesture, "doubleTap")
        XCTAssertEqual(row.trigger.outputMethod, "clipboard")
        let destination = NSRunningApplication.runningApplications(
            withBundleIdentifier: self.fixtureID
        ).first?.localizedName
        XCTAssertEqual(row.trigger.destinationApplication, destination)
        let phases: [ApplicationModelUsagePhase] = failed
            ? [.transcriptionBatch] : [.transcriptionBatch, .postProcessing]
        XCTAssertEqual(row.modelUsages.map(\.phase), phases.map(\.rawValue))
        XCTAssertEqual(row.modelUsages.map(\.modelIdentifier), failed
            ? ["core-journey/batch-fixture"] : ["core-journey/batch-fixture", ModelCatalog.defaultPostProcessingModel])
        XCTAssertEqual(row.errors.map(\.phase), failed ? [ApplicationHistoryError.Phase.postProcessing.rawValue] : [])
        if failed { XCTAssertTrue(row.errors.first?.message.contains("Synthetic post-processing rejection") == true) }
        for kind in ["recordingStopped", "transcriptionReceived", "outputDelivered"] {
            XCTAssertEqual(row.events.filter { $0.kind == kind }.count, 1, kind)
        }
        if !failed { XCTAssertEqual(row.events.filter { $0.kind == "postProcessingReceived" }.count, 1) }
        let audio = try XCTUnwrap(row.audioFileURL)
        XCTAssertTrue(audio.resolvingSymlinksInPath().path.hasPrefix(
            self.directory.appendingPathComponent("Recordings").resolvingSymlinksInPath().path + "/"))
        XCTAssertEqual(try Data(contentsOf: audio).count, 8_044)
    }

    func assertGestures(runs: Int, terminalStates: [String]) throws {
        let snapshot = try CoreJourneyGestureDriver.snapshot(at: self.diagnostics)
        XCTAssertEqual(snapshot.processID, self.process?.processIdentifier)
        let states = ["idle"] + terminalStates.flatMap { ["recording", "processing", "delivering", $0] }
        XCTAssertEqual(snapshot.states, states)
        XCTAssertEqual(snapshot.events.filter { $0.source == "carbon" }.map(\.stage),
                       (0..<runs).flatMap { _ in ["doubleTap", "singleTap"] })
        XCTAssertEqual(snapshot.events.filter { $0.stage == "keyDown" }.count, 3 * runs)
        XCTAssertEqual(snapshot.events.filter { $0.stage == "keyUp" }.count, 3 * runs)
        XCTAssertTrue(snapshot.events.allSatisfy { $0.frontmostBundleID == self.fixtureID })
    }

    private func registerCleanup(suite: String) {
        let previous = NSPasteboard.general.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let cleanup: () throws -> Void = {
            for path in ["hotkey-probe.json", "batch-http.json", "SpeakApp/History/history-log.json"] {
                if let data = try? Data(contentsOf: self.directory.appendingPathComponent(path)) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    attachment.name = path
                    attachment.lifetime = .keepAlways
                    self.owner.add(attachment)
                }
            }
            for app in [self.app, self.fixture] where app.state != .notRunning {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                self.owner.add(screenshot)
                app.terminate()
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(previous)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: self.directory)
        }
        self.owner.addTeardownBlock(cleanup)
    }
}

private struct PolishHistoryRow: Decodable, Equatable {
    struct Trigger: Decodable, Equatable {
        let gesture: String
        let outputMethod: String
        let destinationApplication: String?
    }
    struct Usage: Decodable, Equatable { let phase: String; let modelIdentifier: String }
    struct Event: Decodable, Equatable { let kind: String }
    struct Failure: Decodable, Equatable { let phase: String; let message: String }
    let id: UUID
    let rawTranscription: String?
    let postProcessedTranscription: String?
    let recordingDuration: TimeInterval
    let audioFileURL: URL?
    let trigger: Trigger
    let modelUsages: [Usage]
    let events: [Event]
    let errors: [Failure]
}
