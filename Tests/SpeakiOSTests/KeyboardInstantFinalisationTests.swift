#if os(iOS)
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class KeyboardInstantFinalisationTests: XCTestCase {
    func testQueuedFinish_disruptionClaimsFirstAndCompletesOnce() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let request = try harness.startRequest()
        try harness.keyboard.requestFinish(requestID: request.requestID)
        let draining = expectation(description: "Disruption drain started")
        harness.drain.onWait = { draining.fulfill() }
        let disruption = Task { @MainActor in
            // Queue the keyboard Finish, then enter the disruption callback before that task runs.
            harness.coordinator.handleRequestChange()
            await harness.coordinator.finishRecording(for: request.requestID)
        }
        await fulfillment(of: [draining], timeout: 2)
        await harness.coordinator.requestTask?.value
        XCTAssertFalse(harness.running)
        XCTAssertEqual(harness.app.activeRecord()?.phase, .transcribing)
        XCTAssertNil(harness.app.activeRecord()?.failureCode)
        await harness.coordinator.finishRecording(for: request.requestID)
        harness.drain.release()
        await disruption.value
        await harness.coordinator.finishRecording(for: request.requestID)
        harness.assertCompleted(request.requestID, text: "Captured words")
    }

    func testKeyboardFinishFirst_duplicateDisruptionDuringDrainAndPolishCompletesOnce() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let request = try harness.startRequest(polishes: true)
        try harness.keyboard.requestFinish(requestID: request.requestID)
        let draining = expectation(description: "Keyboard drain started")
        let polishing = expectation(description: "Polish started")
        harness.drain.onWait = { draining.fulfill() }
        harness.polish.onWait = { polishing.fulfill() }
        harness.coordinator.handleRequestChange()
        let keyboardFinish = harness.coordinator.requestTask
        await fulfillment(of: [draining], timeout: 2)
        await harness.coordinator.finishRecording(for: request.requestID)
        harness.drain.release()
        await fulfillment(of: [polishing], timeout: 2)
        await harness.coordinator.finishRecording(for: request.requestID)
        XCTAssertEqual(harness.app.activeRecord()?.phase, .transcribing)
        XCTAssertTrue(harness.history.items.isEmpty)
        harness.polish.release()
        await keyboardFinish?.value
        harness.assertCompleted(request.requestID, text: "Polished words")
        XCTAssertEqual(harness.polishes, 1)
    }

    func testDuplicateDuringPolishFailure_preservesRawHistoryAndRealFailure() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let request = try harness.startRequest(polishes: true)
        harness.polishFails = true
        let polishing = expectation(description: "Polish started")
        harness.polish.onWait = { polishing.fulfill() }
        harness.drain.release()
        let finish = Task { await harness.coordinator.finishRecording(for: request.requestID) }
        await fulfillment(of: [polishing], timeout: 2)
        await harness.coordinator.finishRecording(for: request.requestID)
        harness.polish.release()
        await finish.value
        XCTAssertEqual(harness.app.activeRecord()?.phase, .failed)
        XCTAssertEqual(harness.app.activeRecord()?.failureCode, .profileUnavailable)
        XCTAssertEqual(harness.history.items.count, 1)
        XCTAssertEqual(harness.savedTexts, ["Captured words"])
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.resumptions, 1)
    }

    func testEmptyFinalResult_duplicateFinishKeepsNoSpeechFailure() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let request = try harness.startRequest()
        harness.resultText = ""
        let draining = expectation(description: "Drain started")
        harness.drain.onWait = { draining.fulfill() }
        let finish = Task { await harness.coordinator.finishRecording(for: request.requestID) }
        await fulfillment(of: [draining], timeout: 2)
        await harness.coordinator.finishRecording(for: request.requestID)
        harness.drain.release()
        await finish.value
        XCTAssertEqual(harness.app.activeRecord()?.failureCode, .noSpeech)
        XCTAssertTrue(harness.history.items.isEmpty)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.resumptions, 1)
    }

    func testCancelDuringDrain_lateResultCannotCompleteOrResumeTwice() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let request = try harness.startRequest()
        let draining = expectation(description: "Drain started")
        harness.drain.onWait = { draining.fulfill() }
        let finish = Task { await harness.coordinator.finishRecording(for: request.requestID) }
        await fulfillment(of: [draining], timeout: 2)
        try harness.keyboard.cancel(requestID: request.requestID)
        harness.coordinator.cancelRecording(for: request.requestID)
        await harness.coordinator.finishRecording(for: request.requestID)
        harness.drain.release()
        await finish.value
        await Task { @MainActor in }.value
        XCTAssertEqual(harness.app.activeRecord()?.phase, .cancelled)
        XCTAssertTrue(harness.history.items.isEmpty)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.resumptions, 1)
    }

    func testCancelDuringPolish_lateResultCannotComplete() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let request = try harness.startRequest(polishes: true)
        let polishing = expectation(description: "Polish started")
        harness.polish.onWait = { polishing.fulfill() }
        harness.drain.release()
        let finish = Task { await harness.coordinator.finishRecording(for: request.requestID) }
        await fulfillment(of: [polishing], timeout: 2)
        try harness.keyboard.cancel(requestID: request.requestID)
        harness.polish.release()
        await finish.value
        XCTAssertEqual(harness.app.activeRecord()?.phase, .cancelled)
        XCTAssertTrue(harness.history.items.isEmpty)
        XCTAssertEqual(harness.resumptions, 1)
    }

    func testReplacementRequest_oldDrainCannotClearNewOwnerOrItsClaim() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let first = try harness.startRequest()
        let oldDrain = harness.drain
        let oldStarted = expectation(description: "Old drain started")
        oldDrain.onWait = { oldStarted.fulfill() }
        let oldFinish = Task { await harness.coordinator.finishRecording(for: first.requestID) }
        await fulfillment(of: [oldStarted], timeout: 2)
        try harness.keyboard.cancel(requestID: first.requestID)
        harness.coordinator.cancelRecording(for: first.requestID)
        await Task { @MainActor in }.value
        harness.drain = Gate()
        harness.resultText = "Replacement words"
        let second = try harness.startRequest()
        let newStarted = expectation(description: "New drain started")
        harness.drain.onWait = { newStarted.fulfill() }
        let newFinish = Task { await harness.coordinator.finishRecording(for: second.requestID) }
        await fulfillment(of: [newStarted], timeout: 2)
        oldDrain.release()
        await oldFinish.value
        await harness.coordinator.finishRecording(for: first.requestID)
        await harness.coordinator.finishRecording(for: second.requestID)
        XCTAssertEqual(harness.app.activeRecord()?.requestID, second.requestID)
        XCTAssertEqual(harness.app.activeRecord()?.phase, .transcribing)
        XCTAssertTrue(harness.history.items.isEmpty)
        harness.drain.release()
        await newFinish.value
        XCTAssertEqual(harness.app.activeRecord()?.phase, .completed)
        XCTAssertEqual(harness.savedTexts, ["Replacement words"])
        XCTAssertEqual(harness.app.readyResult(requestID: second.requestID), "Replacement words")
        XCTAssertEqual(harness.stops, 2)
        XCTAssertEqual(harness.resumptions, 2)
    }
}

@MainActor
private final class Gate {
    var onWait: () -> Void = {}
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            onWait()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Harness {
    let suite = "KeyboardInstantFinalisationTests.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let app: KeyboardHandoffStore
    let keyboard: KeyboardHandoffStore
    let history: iOSHistoryManager
    let coordinator: KeyboardInstantDictationCoordinator
    var drain = Gate()
    var polish = Gate()
    var running = false
    var stops = 0
    var polishes = 0
    var resumptions = 0
    var savedTexts: [String] = []
    var resultText = "Captured words"
    var polishFails = false

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        app = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        keyboard = KeyboardHandoffStore(defaults: defaults, role: .keyboardExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"), syncEnabled: false, userDefaults: defaults
        )
        let sessions = KeyboardInstantDictationStore(defaults: defaults)
        _ = sessions.start(enabling: true)
        coordinator = KeyboardInstantDictationCoordinator(sessionStore: sessions, handoffStore: app)
        coordinator.finalisation = .init(
            isRunning: { [unowned self] in self.running },
            partialText: { "Captured partial" },
            stop: { [unowned self] in
                self.stops += 1
                self.running = false
                let text = self.resultText
                await self.drain.wait()
                return TranscriptionResult(
                    text: text, segments: [], confidence: nil, duration: 3,
                    modelIdentifier: "test-model", cost: nil, rawPayload: nil, debugInfo: nil
                )
            },
            cancel: { [unowned self] in self.running = false },
            polish: { [unowned self] _, _ in
                self.polishes += 1
                await self.polish.wait()
                if self.polishFails { throw PostProcessingError.emptyResult }
                return "Polished words"
            },
            save: { [unowned self] text, result in
                self.savedTexts.append(text)
                self.history.recordTranscription(text: text, model: result.modelIdentifier, duration: result.duration)
            },
            resumeReadiness: { [unowned self] in self.resumptions += 1 }
        )
    }

    func startRequest(polishes: Bool = false) throws -> KeyboardHandoffRecord {
        let profile = KeyboardDictationProfileOption(
            id: "test", displayName: "Test", chipLabel: "Test", route: .appHandoff,
            transcriptionMode: .streaming, transcriptionModelIdentifier: "test-model",
            languageIdentifier: "en", postProcessingEnabled: polishes,
            postProcessingModelIdentifier: polishes ? "test-polish" : nil
        )
        let request = try keyboard.createRequest(profile: profile)
        try app.markRecording(requestID: request.requestID)
        coordinator.claimRecording(for: request)
        running = true
        return request
    }

    func assertCompleted(_ requestID: UUID, text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.activeRecord()?.requestID, requestID, file: file, line: line)
        XCTAssertEqual(app.activeRecord()?.phase, .completed, file: file, line: line)
        XCTAssertEqual(app.activeRecord()?.transcript, text, file: file, line: line)
        XCTAssertEqual(app.readyResult(requestID: requestID), text, file: file, line: line)
        XCTAssertNil(app.readyResult(requestID: UUID()), file: file, line: line)
        XCTAssertNil(app.activeRecord()?.failureCode, file: file, line: line)
        XCTAssertEqual(stops, 1, file: file, line: line)
        XCTAssertEqual(history.items.count, 1, file: file, line: line)
        XCTAssertEqual(savedTexts, [text], file: file, line: line)
        XCTAssertEqual(resumptions, 1, file: file, line: line)
    }

    func cleanUp() {
        drain.release()
        polish.release()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
