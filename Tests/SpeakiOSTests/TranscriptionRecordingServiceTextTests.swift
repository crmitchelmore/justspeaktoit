#if os(iOS)
import AppIntents
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
    func testCancellingRecordingBPreservesRecordingAPolishAndHistory() async throws {
        let suiteName = "TranscriptionRecordingServiceTextTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let sharedState = SharedTranscriptionState(defaults: defaults)
        let history = iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"),
            syncEnabled: false,
            userDefaults: defaults
        )
        let pasteboard = RecordingTestPasteboard()
        var continuation: CheckedContinuation<String, Error>?
        let service = TranscriptionRecordingService(
            sharedState: sharedState,
            historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard),
            hasPolishingKey: { true },
            polish: { _, _, _ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
        )

        defaults.set("Recording A", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false)
        let result = await service.stopRecording(destination: .clipboardAndPostProcess)
        XCTAssertEqual(result.text, "Recording A")
        let itemA = try XCTUnwrap(history.items.first)
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        let pendingPolish = try XCTUnwrap(continuation)
        XCTAssertTrue(history.reprocessingIDs.contains(itemA.id))

        defaults.set("Recording B", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false)
        XCTAssertTrue(service.isRunning)
        service.cancelRecording()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertTrue(history.reprocessingIDs.contains(itemA.id), "B must not end A's processing indicator")

        pendingPolish.resume(returning: "Polished recording A")
        for _ in 0..<1_000 where history.reprocessingIDs.contains(itemA.id) { await Task.yield() }
        XCTAssertTrue(history.reprocessingIDs.isEmpty)
        XCTAssertEqual(history.items.first?.id, itemA.id)
        XCTAssertEqual(history.items.first?.postProcessedTranscription, "Polished recording A")
        XCTAssertEqual(sharedState.lastCompletedTranscript, "Polished recording A")
        XCTAssertEqual(pasteboard.string, "Recording A")
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
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"), syncEnabled: false, userDefaults: defaults
        )
        let shared = SharedTranscriptionState(defaults: defaults)
        let board = RecordingTestPasteboard()
        var continuation: CheckedContinuation<String, Error>?
        let service = TranscriptionRecordingService(
            sharedState: shared,
            historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: board),
            hasPolishingKey: { keyAvailable },
            polish: { _, _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        )
        defer { service.cancelRecording() }
        defaults.set("Raw transcript", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false)
        await service.stopRecording(destination: destination)
        XCTAssertEqual(board.writes, ["Raw transcript"], "Stop must make raw text immediately available")
        if keyAvailable {
            for _ in 0..<1_000 where continuation == nil { await Task.yield() }
            let pending = try XCTUnwrap(continuation)
            if copy.changed { board.string = copy.text }
            if fails {
                pending.resume(throwing: URLError(.timedOut))
            } else {
                pending.resume(returning: "Polished transcript")
            }
            for _ in 0..<1_000 where !history.reprocessingIDs.isEmpty { await Task.yield() }
        } else {
            XCTAssertNil(continuation, "Missing key must leave the initial raw copy intact")
        }
        XCTAssertTrue(history.reprocessingIDs.isEmpty)
        XCTAssertEqual(board.writes, ["Raw transcript"], "No second write, even if clipboard is unchanged")
        XCTAssertEqual(board.string, copy.changed ? copy.text : "Raw transcript")
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(
            history.items.first?.postProcessedTranscription, keyAvailable && !fails ? "Polished transcript" : nil
        )
        XCTAssertEqual(
            shared.lastCompletedTranscript, keyAvailable && !fails ? "Polished transcript" : "Raw transcript"
        )
    }
}
#endif

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
