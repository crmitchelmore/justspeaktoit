import AppKit
import XCTest

/// Remaining #802 P0 launched-app journeys. Each drives the real Speak process
/// from the supported global chord through production session orchestration.
final class CoreJourneyP0UITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testStreaming_partialsBecomeOneFinalTranscriptWithoutDuplication() throws {
        let journey = try P0Journey(self, scenario: "streamingOff")
        let partials = [
            "Streaming", "Streaming partial", "Streaming partials become", "Streaming partials become one final"
        ]
        let final = "Streaming partials become one final transcript."
        try journey.record(expecting: "completed") {
            // Partials must reach production's live transcript while recording,
            // before the stop gesture, and must not be delivered on their own.
            journey.waitUntil("Every stub partial must reach the production live transcript") {
                guard let live = try? journey.streaming(), live.emittedPartials == partials,
                      let previews = try? CoreJourneyGestureDriver.snapshot(at: journey.diagnostics).livePreviews
                else { return false }
                return previews.filter { !$0.isEmpty } == partials
            }
            journey.assertUntouched()
        }
        try journey.assertDelivered(final)
        let live = try journey.streaming()
        XCTAssertEqual(live.model, "core-journey/streaming-fixture")
        XCTAssertEqual(live.starts, 1)
        XCTAssertEqual(live.stops, 1)
        XCTAssertEqual(live.finals, [final])
        XCTAssertEqual(live.unexpectedModels, [])
        let previews = try XCTUnwrap(CoreJourneyGestureDriver.snapshot(at: journey.diagnostics).livePreviews)
            .filter { !$0.isEmpty }
        XCTAssertEqual(Array(previews.prefix(partials.count)), partials)
        XCTAssertTrue(previews.dropFirst(partials.count).allSatisfy { $0 == final },
                      "After the partials only the final may be displayed: \(previews)")
        XCTAssertFalse(journey.httpExists, "The streaming route must not issue a batch provider request")
        let row = try XCTUnwrap(journey.history(count: 1).first)
        try journey.assertSuccessRow(row, raw: final, usage: ["live"], model: "core-journey/streaming-fixture")
        try journey.assertGestures(terminalStates: ["completed"])
    }

    @MainActor
    func testTargetChange_duringRecordingDeliversToCapturedAppNotNewFrontmostApp() throws {
        let journey = try P0Journey(self, scenario: nil)
        let transcript = "A complete batch journey, through the clipboard."
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        try journey.record(expecting: "completed", stopFrom: finder) {
            journey.assertUntouched()
            finder.activate()
            journey.waitUntil("Focus must move to another application while recording") {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
            }
        }
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), transcript)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.finder",
                       "Delivery must not pull the captured app back to the front")
        let snapshot = try CoreJourneyGestureDriver.snapshot(at: journey.diagnostics)
        // PID-directed paste can only reach the captured fixture, never Finder.
        journey.waitForField(snapshot.eventPostingAllowed ? journey.initialField + transcript : journey.initialField)
        try journey.assertHTTP(accepted: 1)
        let row = try XCTUnwrap(journey.history(count: 1).first)
        try journey.assertSuccessRow(row, raw: transcript, usage: ["batch"], model: "core-journey/batch-fixture")
        // Production may append the settings remedy after the note.
        let movedNote = "Delivery warning: Sent to the app where recording started."
        XCTAssertTrue(row.events.contains { $0.kind == "outputDelivered" && $0.description.hasPrefix(movedNote) },
                      "History must record that focus moved and the captured app received the transcript")
        let carbon = snapshot.events.filter { $0.source == "carbon" }
        XCTAssertEqual(carbon.map(\.stage), ["doubleTap", "singleTap"])
        XCTAssertEqual(carbon.map(\.frontmostBundleID), [journey.fixtureID, "com.apple.finder"])
        XCTAssertEqual(snapshot.states, ["idle", "recording", "processing", "delivering", "completed"])
    }

    /// Production treats an empty provider transcript as a failed transcription:
    /// nothing reaches the clipboard or field, and History keeps only a failure
    /// record with no transcript text (no placeholder, no delivery).
    @MainActor
    func testSilentInput_leavesClipboardAndFieldUntouchedAndStoresNoTranscript() throws {
        let journey = try P0Journey(self, scenario: "batchSilentInput")
        try journey.record(expecting: "failed") { journey.assertUntouched() }
        // Allow several History flush intervals before proving nothing was delivered.
        Thread.sleep(forTimeInterval: 2)
        journey.assertUntouched()
        try journey.assertHTTP(accepted: 1)
        let row = try XCTUnwrap(journey.history(count: 1).first)
        XCTAssertNil(row.rawTranscription, "Silence must not store transcript or placeholder text")
        XCTAssertNil(row.postProcessedTranscription)
        XCTAssertEqual(row.trigger.outputMethod, "none")
        XCTAssertEqual(row.errors.map(\.phase), ["transcription"])
        XCTAssertFalse(row.events.contains { $0.kind == "outputDelivered" || $0.kind == "transcriptionReceived" })
        let snapshot = try CoreJourneyGestureDriver.snapshot(at: journey.diagnostics)
        XCTAssertEqual(snapshot.states, ["idle", "recording", "processing", "failed"])
    }

    @MainActor
    func testMissingTranscriptionKey_failsVisiblyThenNextRunSucceeds() throws {
        let journey = try P0Journey(self, scenario: "batchMissingKeyThenRecovery")
        let transcript = "A complete batch journey, through the clipboard."
        try journey.record(expecting: "failed") { journey.assertUntouched() }
        journey.assertVisibleHUD(containing: ["Batch transcription requires an OpenRouter API key", "Settings"])
        Thread.sleep(forTimeInterval: 1)
        journey.assertUntouched()
        XCTAssertFalse(journey.httpExists, "No provider request may be made without a credential")
        let failed = try XCTUnwrap(journey.history(count: 1).first)
        XCTAssertNil(failed.rawTranscription)
        XCTAssertEqual(failed.errors.map(\.phase), ["transcription"])
        XCTAssertEqual(failed.errors.first?.message,
                       "Batch transcription requires an OpenRouter API key. Add one in Settings › API Keys.")
        XCTAssertFalse(failed.events.contains { $0.kind == "outputDelivered" })

        // The user adds a credential; the same running process records again.
        try journey.provideCredential()
        try journey.record(expecting: "completed") {
            XCTAssertEqual(journey.target.value as? String, journey.initialField)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), journey.initialClipboard)
        }
        try journey.assertDelivered(transcript)
        try journey.assertHTTP(accepted: 1)
        let rows = try journey.history(count: 2)
        XCTAssertEqual(rows.filter { $0.id == failed.id }, [failed], "Recovery must not rewrite the failed row")
        let recovered = try XCTUnwrap(rows.first { $0.id != failed.id })
        try journey.assertSuccessRow(recovered, raw: transcript, usage: ["batch"], model: "core-journey/batch-fixture")
        try journey.assertGestures(terminalStates: ["failed", "completed"])
    }
}

@MainActor
private final class P0Journey {
    let initialClipboard = "core journey clipboard before recording"
    let initialField = "Target: "
    let fixtureID = "com.justspeaktoit.core-journey-fixture"
    let diagnostics: URL
    private let app = XCUIApplication(bundleIdentifier: "com.justspeaktoit.mac")
    private let fixture = XCUIApplication(bundleIdentifier: "com.justspeaktoit.core-journey-fixture")
    private let directory: URL
    private let identifier: UUID
    private unowned let owner: XCTestCase
    private var process: NSRunningApplication?
    private var delivered: [String] = []
    var target: XCUIElement { fixture.textViews["coreJourneyTargetField"] }
    var httpExists: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("batch-http.json").path)
    }

    init(_ owner: XCTestCase, scenario: String?) throws {
        self.owner = owner
        let identifier = UUID()
        self.identifier = identifier
        let suite = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(suite)
        diagnostics = directory.appendingPathComponent("hotkey-probe.json")
        app.launchEnvironment["SPEAK_CORE_JOURNEY_PROFILE"] = identifier.uuidString
        app.launchEnvironment["SPEAK_CORE_JOURNEY_DIRECTORY"] = directory.path
        if let scenario {
            app.launchEnvironment["SPEAK_CORE_JOURNEY_SCENARIO"] = scenario
        } else {
            app.launchEnvironment["SPEAK_CORE_JOURNEY_BATCH"] = "1"
        }
        app.launchArguments = ["-hasCompletedOnboarding", "YES", "-hasAnsweredAnalyticsConsent", "YES"]
        registerCleanup(suite: suite)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(initialClipboard, forType: .string))
        app.launch()
        XCTAssertTrue(app.buttons["toolbarRecordToggleButton"].waitForExistence(timeout: 15))
        CoreJourneyGestureDriver.wait(at: diagnostics, message: "Production hotkey must register") {
            $0.registered && $0.states == ["idle"]
        }
        process = try XCTUnwrap(NSRunningApplication(
            processIdentifier: CoreJourneyGestureDriver.snapshot(at: diagnostics).processID
        ))
        XCTAssertEqual(process?.bundleIdentifier, "com.justspeaktoit.mac")
        fixture.launch()
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()
        target.typeText(initialField)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
    }

    /// Double-tap starts and a later single tap stops through real Carbon delivery.
    /// `expecting` nil accepts either terminal state and returns the observed one.
    @discardableResult
    func record(expecting terminal: String?, stopFrom stopper: XCUIApplication? = nil,
                onRecording: () -> Void) throws -> String {
        let offset = try CoreJourneyGestureDriver.snapshot(at: diagnostics).states.count
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        fixture.typeKey("k", modifierFlags: [.control, .option, .shift])
        CoreJourneyGestureDriver.wait(at: diagnostics, message: "Fresh Carbon double-tap must start recording") {
            $0.states.dropFirst(offset).last == "recording"
        }
        onRecording()
        CoreJourneyGestureDriver.wait(at: diagnostics, message: "Recording must survive the stop-gesture window") {
            guard let lastEvent = $0.events.last else { return false }
            return $0.states.dropFirst(offset).last == "recording"
                && ProcessInfo.processInfo.systemUptime - lastEvent.uptime > 15.2
        }
        (stopper ?? fixture).typeKey("k", modifierFlags: [.control, .option, .shift])
        let terminals = terminal.map { [$0] } ?? ["completed", "failed"]
        CoreJourneyGestureDriver.wait(at: diagnostics, message: "Recording must reach \(terminals)") {
            $0.states.dropFirst(offset).last.map(terminals.contains) == true
        }
        return try XCTUnwrap(CoreJourneyGestureDriver.snapshot(at: diagnostics).states.last)
    }

    func waitUntil(_ message: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let ready = NSPredicate { _, _ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)],
                                      timeout: timeout), .completed, message)
    }

    func assertUntouched() {
        XCTAssertEqual(target.value as? String, initialField)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), initialClipboard)
    }

    func waitForField(_ expected: String) {
        waitUntil("Field contents must follow actual OS event-posting permission", timeout: 5) {
            self.target.value as? String == expected
        }
    }

    func assertDelivered(_ text: String) throws {
        delivered.append(text)
        let snapshot = try CoreJourneyGestureDriver.snapshot(at: diagnostics)
        XCTAssertEqual(snapshot.processID, process?.processIdentifier)
        XCTAssertFalse(try XCTUnwrap(process).isTerminated)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
        waitForField(snapshot.eventPostingAllowed ? initialField + delivered.joined() : initialField)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, fixtureID)
        let coverage = XCTAttachment(string: snapshot.eventPostingAllowed
            ? "Native PID-directed paste observed; physical microphone and direct AX insertion untested."
            : "Clipboard/History observed; OS event posting unavailable, native editor insertion untested.")
        coverage.name = "Actual delivery coverage"
        coverage.lifetime = .keepAlways
        owner.add(coverage)
    }

    func assertVisibleHUD(containing required: [String]) {
        let hud = app.dialogs.descendants(matching: .any).matching(identifier: "hudOverlay").firstMatch
        var labels: [String] = []
        waitUntil("The production HUD must show the actionable error", timeout: 5) {
            guard hud.exists else { return false }
            labels = hud.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
            return labels.contains { label in required.allSatisfy { label.contains($0) } }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Visible production failure: \(labels.joined(separator: " | "))"
        screenshot.lifetime = .keepAlways
        owner.add(screenshot)
    }

    /// The sandboxed runner cannot write into the app's directory; the app saves
    /// the fixture key on this UUID-scoped notification and acknowledges it.
    func provideCredential() throws {
        let name = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString).provide-credential"
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true
        )
        let acknowledgement = directory.appendingPathComponent("fixture-credential.json")
        waitUntil("The running app must acknowledge the saved credential") {
            FileManager.default.fileExists(atPath: acknowledgement.path)
        }
    }

    func assertHTTP(accepted: Int) throws {
        let result = try JSONDecoder().decode(
            P0HTTP.self, from: Data(contentsOf: directory.appendingPathComponent("batch-http.json"))
        )
        XCTAssertEqual(result.acceptedRequests, accepted)
        XCTAssertEqual(result.rejectedRequests, 0, "No unexpected provider request is permitted")
    }

    func streaming() throws -> P0Streaming {
        try JSONDecoder().decode(P0Streaming.self,
                                 from: Data(contentsOf: directory.appendingPathComponent("streaming-live.json")))
    }

    func historyRows() throws -> [P0HistoryRow] {
        let path = directory.appendingPathComponent("SpeakApp/History/history-log.json")
        guard let data = try? Data(contentsOf: path) else { return [] }
        return try JSONDecoder().decode([P0HistoryRow].self, from: data)
    }

    func history(count: Int) throws -> [P0HistoryRow] {
        waitUntil("The real HistoryManager must durably flush exactly the admitted rows") {
            (try? self.historyRows().count) == count
        }
        return try historyRows()
    }

    func assertSuccessRow(_ row: P0HistoryRow, raw: String, usage: [String], model: String) throws {
        XCTAssertEqual(row.rawTranscription, raw)
        XCTAssertNil(row.postProcessedTranscription)
        XCTAssertEqual(row.trigger.gesture, "doubleTap")
        XCTAssertEqual(row.trigger.outputMethod, "clipboard")
        XCTAssertEqual(row.trigger.destinationApplication,
                       NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).first?.localizedName)
        XCTAssertEqual(row.modelUsages.map(\.phase), usage)
        XCTAssertEqual(row.modelUsages.map(\.modelIdentifier), [model])
        XCTAssertEqual(row.errors, [])
        for kind in ["recordingStopped", "transcriptionReceived"] {
            XCTAssertEqual(row.events.filter { $0.kind == kind }.count, 1, kind)
        }
        let deliveries = row.events.filter {
            $0.kind == "outputDelivered" && $0.description == "Output delivered successfully"
        }
        XCTAssertEqual(deliveries.count, 1, "Exactly one delivery")
    }

    func assertGestures(terminalStates: [String]) throws {
        let snapshot = try CoreJourneyGestureDriver.snapshot(at: diagnostics)
        XCTAssertEqual(snapshot.processID, process?.processIdentifier)
        let states = ["idle"] + terminalStates.flatMap { terminal in
            terminal == "failed"
                ? ["recording", "processing", terminal]
                : ["recording", "processing", "delivering", terminal]
        }
        XCTAssertEqual(snapshot.states, states)
        XCTAssertEqual(snapshot.events.filter { $0.source == "carbon" }.map(\.stage),
                       terminalStates.flatMap { _ in ["doubleTap", "singleTap"] })
        XCTAssertTrue(snapshot.events.allSatisfy { $0.frontmostBundleID == fixtureID })
    }

    private func registerCleanup(suite: String) {
        let previous: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let cleanup: () throws -> Void = {
            for path in ["hotkey-probe.json", "batch-http.json", "streaming-live.json",
                         "SpeakApp/History/history-log.json"] {
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
        owner.addTeardownBlock(cleanup)
    }
}

private struct P0HTTP: Decodable {
    let acceptedRequests: Int
    let rejectedRequests: Int
}

private struct P0Streaming: Decodable {
    let model: String?
    let starts: Int
    let stops: Int
    let emittedPartials: [String]
    let finals: [String]
    let unexpectedModels: [String]
}

private struct P0HistoryRow: Decodable, Equatable {
    struct Trigger: Decodable, Equatable {
        let gesture: String
        let outputMethod: String
        let destinationApplication: String?
    }
    struct Usage: Decodable, Equatable { let phase: String; let modelIdentifier: String }
    struct Event: Decodable, Equatable { let kind: String; let description: String }
    struct Failure: Decodable, Equatable { let phase: String; let message: String }
    let id: UUID
    let rawTranscription: String?
    let postProcessedTranscription: String?
    let trigger: Trigger
    let modelUsages: [Usage]
    let events: [Event]
    let errors: [Failure]
}
