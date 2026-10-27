#if os(iOS)
import AppIntents
import Combine
import XCTest

@testable import SpeakiOSLib

/// Covers the stop-time transcript selection that keeps the clipboard, history
/// entry, and spoken "Copied N words" dialog consistent — the fix for short
/// background recordings landing an empty clipboard.
@MainActor
final class TranscriptionRecordingServiceTextTests: XCTestCase {

    func testClipboardDestinationCopiesTranscriptAtStop() {
        XCTAssertEqual(
            TranscriptionRecordingService.clipboardTextAtStop(
                transcript: "Action button transcript",
                destination: .clipboard
            ),
            "Action button transcript"
        )
    }

    func testPolishWithoutAPIKeyCopiesRawTranscriptInsteadOfPermanentPlaceholder() {
        XCTAssertEqual(
            TranscriptionRecordingService.clipboardTextAtStop(
                transcript: "Action button transcript",
                destination: .clipboardAndPostProcess
            ),
            "Action button transcript"
        )
    }

    func testPolishCopiesRawTranscriptImmediately() {
        XCTAssertEqual(
            TranscriptionRecordingService.clipboardTextAtStop(
                transcript: "Action button transcript",
                destination: .clipboardAndPostProcess
            ),
            "Action button transcript"
        )
    }

    func testHistoryOnlyDoesNotTouchClipboard() {
        XCTAssertNil(
            TranscriptionRecordingService.clipboardTextAtStop(
                transcript: "Action button transcript",
                destination: .historyOnly
            )
        )
    }

    func testKeyboardHandoffDoesNotPublishTranscriptToLegacySharedState() {
        XCTAssertNil(
            TranscriptionRecordingService.legacySharedTranscript(
                "Private keyboard transcript",
                sharesCompletedTranscript: false
            )
        )
    }

    @available(iOS 18, *)
    func testLiveActivityStopIntentKeepsAudioRecordingExecutionContext() {
        let intentType: any AudioRecordingIntent.Type = StopTranscriptionRecordingIntent.self
        XCTAssertTrue(intentType == StopTranscriptionRecordingIntent.self)
    }

    @available(iOS 18, *)
    func testToggleIntentDoesNotExposeStatusTextAsShortcutOutput() {
        // The closure is intentionally not executed: this is a compile-time
        // assertion that the toggle intent's Result.Dialog type is Never.
        func requireDialogFreeResult<Result: IntentResult>(
            _ operation: @escaping () async throws -> Result
        ) where Result.Dialog == Never {
            _ = operation
        }

        requireDialogFreeResult {
            try await StartTranscriptionRecordingIntent().perform()
        }
    }

    func testPrefersTranscriberResultWhenPresent() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["final result", "interim", "older"],
            fallback: ""
        )
        XCTAssertEqual(text, "final result")
    }

    func testFallsBackToInterimWhenResultBlank() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["", "interim words", "older"],
            fallback: ""
        )
        XCTAssertEqual(text, "interim words")
    }

    func testFallsBackToLastCompletedWhenResultAndInterimBlank() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["   ", "", "last completed"],
            fallback: ""
        )
        XCTAssertEqual(text, "last completed")
    }

    func testWhitespaceOnlyCandidatesAreSkipped() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["  ", "\n", "\t"],
            fallback: "fallback"
        )
        XCTAssertEqual(text, "fallback")
    }

    #if DEBUG && targetEnvironment(simulator)
    func testDisruption_preservesHistoryOnlyDestinationAndKeyboardCompletionOwner() async throws {
        let suiteName = "CaptureDisruption.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let sharedState = SharedTranscriptionState(defaults: defaults)
        let history = iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"), syncEnabled: false, userDefaults: defaults
        )
        let pasteboard = RecordingTestPasteboard()
        pasteboard.string = "User clipboard"
        let service = TranscriptionRecordingService(
            sharedState: sharedState, historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard),
            hasPolishingKey: { false }, polish: { text, _, _ in text }
        )
        defaults.set("Saved before microphone changed", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false, destination: .historyOnly)
        await service.finishCaptureAfterDisruption()
        await service.finishCaptureAfterDisruption()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(pasteboard.string, "User clipboard")

        var keyboardResults: [String] = []
        defaults.set("Owned keyboard transcript", forKey: "simulatorValidationTranscript")
        try await service.startRecording(
            sharesLiveTranscript: false, requiresLiveActivity: false, destination: .historyOnly,
            onCaptureDisruption: { [weak service] in
                guard let service else { return }
                let result = await service.stopRecording(destination: .historyOnly, saveToHistory: false)
                keyboardResults.append(result.text)
            }
        )
        await service.finishCaptureAfterDisruption()
        await service.finishCaptureAfterDisruption()
        XCTAssertEqual(keyboardResults, ["Owned keyboard transcript"])
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(history.items.count, 1, "Keyboard owner controls its own history")
        XCTAssertEqual(pasteboard.string, "User clipboard")
        XCTAssertNotEqual(sharedState.lastCompletedTranscript, "Owned keyboard transcript")
    }

    func testCancellingRecordingBPreservesRecordingAPolishAndHistory() async throws {
        let suiteName = "TranscriptionRecordingServiceTextTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sharedState = SharedTranscriptionState(defaults: defaults)
        let fixture = historyWithStorage(directory: directory, defaults: defaults)
        let pasteboard = RecordingTestPasteboard()
        let admission = PolishAdmission()
        let service = TranscriptionRecordingService(
            sharedState: sharedState,
            historyManager: fixture.history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard),
            hasPolishingKey: { true },
            polish: { _, _, _ in try await admission.process() }
        )
        let cleanup = HistoryFixtureCleanup(directory: directory, defaults: defaults,
                                            suite: suiteName, history: fixture.history)
        cleanup.register(on: self, terminal: fixture.history.$reprocessingIDs.map(\.isEmpty).eraseToAnyPublisher()) {
            fixture.storage.release()
            admission.cancel()
            service.cancelRecording()
        }

        defaults.set("Recording A", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false)
        let result = await service.stopRecording(destination: .clipboardAndPostProcess)
        XCTAssertEqual(result.text, "Recording A")
        let itemA = try XCTUnwrap(fixture.history.items.first)
        await fulfillment(of: [admission.entered], timeout: 2)
        let pendingPolish = try XCTUnwrap(admission.continuation)
        XCTAssertTrue(fixture.history.reprocessingIDs.contains(itemA.id))

        defaults.set("Recording B", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false)
        XCTAssertTrue(service.isRunning)
        service.cancelRecording()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(fixture.history.items.count, 1)
        XCTAssertTrue(fixture.history.reprocessingIDs.contains(itemA.id), "B must not end A's processing indicator")

        await commitHeldPolish(pendingPolish, history: fixture.history, storage: fixture.storage, id: itemA.id)
        admission.continuation = nil
        XCTAssertTrue(fixture.history.reprocessingIDs.isEmpty)
        XCTAssertEqual(fixture.history.items.first?.id, itemA.id)
        XCTAssertEqual(fixture.history.items.first?.postProcessedTranscription, "Polished recording A")
        XCTAssertEqual(sharedState.lastCompletedTranscript, "Polished recording A")
        XCTAssertEqual(pasteboard.string, "Recording A")
        let persisted = try persistedHistory(at: fixture.file)
        XCTAssertEqual(persisted.first?.id, itemA.id)
        XCTAssertEqual(persisted.first?.postProcessedTranscription, "Polished recording A")
    }
    #endif

    /// A stop with no active session (e.g. the second of a rapid double
    /// Action Button press) must be a no-op: no history entry, no clipboard
    /// write, and an empty result rather than stale text.
    func testStopWhenNotRunningReturnsEmptyNoOpResult() async {
        let service = TranscriptionRecordingService.shared
        XCTAssertFalse(service.isRunning)

        let result = await service.stopRecording()

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.duration, 0)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.partialText, "")
        XCTAssertEqual(service.wordCount, 0)
    }
}
#if DEBUG && targetEnvironment(simulator)
@MainActor
extension TranscriptionRecordingServiceTextTests {
    func testAutomaticDestinationsNeverWritePolishOrRestoreRaw() async throws {
        let settings = AppSettings.shared
        let previous = settings.autoPostProcess
        settings.autoPostProcess = true
        defer { settings.autoPostProcess = previous }

        let copies: [(changed: Bool, text: String?)] = [
            (false, nil), (true, "Different copy"), (true, "Raw transcript"), (true, nil)
        ]
        for destination in [HardwareTriggerDestination.clipboardAndPostProcess, nil] {
            for fails in [false, true] {
                for copy in copies {
                    try await assertRawOnly(destination: destination, keyAvailable: true, fails: fails, copy: copy)
                }
            }
            try await assertRawOnly(destination: destination, keyAvailable: false, fails: false, copy: (false, nil))
        }
    }

    private func assertRawOnly(
        destination: HardwareTriggerDestination?,
        keyAvailable: Bool,
        fails: Bool,
        copy: (changed: Bool, text: String?)
    ) async throws {
        let suite = "RawOnlyClipboardTest.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"), syncEnabled: false, userDefaults: defaults
        )
        let shared = SharedTranscriptionState(defaults: defaults)
        let board = RecordingTestPasteboard()
        let admission = PolishAdmission()
        let service = TranscriptionRecordingService(
            sharedState: shared, historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: board), hasPolishingKey: { keyAvailable },
            polish: { _, _, _ in try await admission.process() }
        )
        let cleanup = HistoryFixtureCleanup(directory: directory, defaults: defaults, suite: suite, history: history)
        cleanup.register(on: self, terminal: history.$reprocessingIDs.map(\.isEmpty).eraseToAnyPublisher()) {
            admission.cancel()
            service.cancelRecording()
        }
        defaults.set("Raw transcript", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false)
        await service.stopRecording(destination: destination)
        XCTAssertEqual(board.writes, ["Raw transcript"], "Stop must make raw text immediately available")
        if keyAvailable {
            await fulfillment(of: [admission.entered], timeout: 2)
            let pending = try XCTUnwrap(admission.continuation)
            let itemID = try XCTUnwrap(history.items.first?.id)
            XCTAssertTrue(history.reprocessingIDs.contains(itemID))
            let (settled, observation) = postProcessingReceipt(history, id: itemID)
            defer { observation.cancel() }
            if copy.changed { board.string = copy.text }
            if fails {
                pending.resume(throwing: URLError(.timedOut))
            } else {
                pending.resume(returning: "Polished transcript")
            }
            admission.continuation = nil
            await fulfillment(of: [settled], timeout: 2)
        } else {
            XCTAssertNil(admission.continuation, "Missing key must leave the initial raw copy intact")
        }
        assertRawOnlyResult(history: history, shared: shared, board: board,
                            expectPolished: keyAvailable && !fails, copy: copy)
    }
    private func assertRawOnlyResult(
        history: iOSHistoryManager, shared: SharedTranscriptionState, board: RecordingTestPasteboard,
        expectPolished: Bool, copy: (changed: Bool, text: String?)
    ) {
        XCTAssertTrue(history.reprocessingIDs.isEmpty)
        XCTAssertEqual(board.writes, ["Raw transcript"], "No second write, even if clipboard is unchanged")
        XCTAssertEqual(board.string, copy.changed ? copy.text : "Raw transcript")
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(
            history.items.first?.postProcessedTranscription, expectPolished ? "Polished transcript" : nil
        )
        XCTAssertEqual(
            shared.lastCompletedTranscript, expectPolished ? "Polished transcript" : "Raw transcript"
        )
    }
    private func postProcessingReceipt(
        _ history: iOSHistoryManager, id: UUID
    ) -> (XCTestExpectation, AnyCancellable) {
        let settled = expectation(description: "Admitted History polish reached its terminal receipt")
        // Require this row's admission before observing its terminal removal; ignore an initial empty set.
        let observation = history.$reprocessingIDs
            .drop(while: { !$0.contains(id) })
            .first(where: { !$0.contains(id) })
            .sink { _ in settled.fulfill() }
        return (settled, observation)
    }
    private func historyWithStorage(
        directory: URL, defaults: UserDefaults
    ) -> RecordingHistoryFixture {
        let file = directory.appendingPathComponent("history.json")
        let storage = HistoryAsyncStorage(primary: file)
        let history = iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults,
                                        storageIO: storage.storageIO)
        return RecordingHistoryFixture(history: history, storage: storage, file: file)
    }
    private func commitHeldPolish(
        _ pending: CheckedContinuation<String, Error>, history: iOSHistoryManager,
        storage: HistoryAsyncStorage, id: UUID
    ) async {
        let writeEntered = expectation(description: "Recording A polished History write admitted")
        storage.holdWrite(writeEntered)
        defer { storage.release() }
        let (settled, observation) = postProcessingReceipt(history, id: id)
        defer { observation.cancel() }
        pending.resume(returning: "Polished recording A")
        await fulfillment(of: [writeEntered], timeout: 2)
        XCTAssertTrue(history.reprocessingIDs.contains(id), "Held A write retains its processing owner")
        XCTAssertNil(history.items.first?.postProcessedTranscription)
        storage.release()
        await fulfillment(of: [settled], timeout: 2)
    }
    private func persistedHistory(at file: URL) throws -> [iOSHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([iOSHistoryItem].self, from: Data(contentsOf: file))
    }
}
#endif
@MainActor
private struct RecordingHistoryFixture {
    let history: iOSHistoryManager
    let storage: HistoryAsyncStorage
    let file: URL
}
@MainActor
private final class PolishAdmission {
    let entered = XCTestExpectation(description: "Polish processor admitted")
    var continuation: CheckedContinuation<String, Error>?
    private var cancelled = false
    func process() async throws -> String {
        guard !cancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
@MainActor
private final class RecordingTestPasteboard: PolishPasteboard {
    var string: String?
    var writes: [String] = []

    func write(_ text: String) {
        string = text
        writes.append(text)
    }
}
#endif
