#if os(iOS) && DEBUG && targetEnvironment(simulator)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class TranscriptionCompletionTests: XCTestCase {
    func testClipboardWithReplacementOwnership_RemainsNeutral() async throws {
        try await assertCompletion(destination: .clipboard, foregroundReceipt: true)
    }

    func testClipboardWithoutReplacementOwnership_RemainsNeutral() async throws {
        try await assertCompletion(destination: .clipboard, foregroundReceipt: false)
    }

    func testPolishWithProvider_CompletesWithRawTextAndNeutralOutcome() async throws {
        try await assertCompletion(destination: .clipboardAndPostProcess, hasPolisher: true)
    }

    func testPolishWithoutProvider_CompletesWithRawTextAndNeutralOutcome() async throws {
        try await assertCompletion(destination: .clipboardAndPostProcess, hasPolisher: false)
    }

    func testHistoryOnly_DoesNotTreatReturnedItemAsDurableSaveReceipt() async throws {
        try await assertCompletion(destination: .historyOnly)
    }

    func testKeyboardBeforeCoordinatorSaveOrInsertion_RemainsNeutral() async throws {
        try await assertCompletion(destination: .historyOnly, saveToHistory: false)
    }

    func testSilentStop_DoesNotClaimDelivery() async throws {
        try await assertCompletion(destination: .clipboard, transcript: "")
    }

    private func assertCompletion(
        destination: HardwareTriggerDestination,
        saveToHistory: Bool = true,
        hasPolisher: Bool = false,
        foregroundReceipt: Bool = true,
        transcript: String = "Raw transcript"
    ) async throws {
        let suiteName = "TranscriptionCompletionTests.\(UUID())"
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
        let pasteboard = CompletionTestPasteboard()
        var outcomes: [TranscriptionCompletionOutcome] = []
        var textAtCompletion: String?
        let service = TranscriptionRecordingService(
            sharedState: sharedState,
            historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard, isActive: { foregroundReceipt }),
            hasPolishingKey: { hasPolisher },
            polish: { _, _, _ in "Polished transcript" },
            completeActivity: { count, _, _, outcome in
                XCTAssertEqual(count, transcript.isEmpty ? 0 : 2)
                textAtCompletion = pasteboard.string
                outcomes.append(outcome)
            }
        )
        defaults.set("Raw transcript", forKey: "simulatorValidationTranscript")
        try await service.startRecording(sharesLiveTranscript: saveToHistory, requiresLiveActivity: false)
        // The fixture bypasses microphone capture. Clear its partial for the silent run.
        service.partialText = transcript
        let result = await service.stopRecording(destination: destination, saveToHistory: saveToHistory)
        XCTAssertEqual(result.text, transcript)
        XCTAssertEqual(outcomes, [transcript.isEmpty ? .noSpeech : .ready])
        XCTAssertEqual(textAtCompletion, destination == .historyOnly || transcript.isEmpty ? nil : transcript)
        XCTAssertEqual(history.items.count, saveToHistory && !transcript.isEmpty ? 1 : 0)
        for _ in 0..<1_000 where !history.reprocessingIDs.isEmpty { await Task.yield() }
        XCTAssertEqual(
            outcomes, [transcript.isEmpty ? .noSpeech : .ready],
            "Polish must not schedule another completion UI update"
        )
        service.cancelRecording()
    }
}

@MainActor
private final class CompletionTestPasteboard: PolishPasteboard {
    var changeCount = 0
    var ownershipToken: String?
    var string: String?

    func write(_ text: String, token: String) {
        string = text
        ownershipToken = token
        changeCount += 1
    }
}
#endif
