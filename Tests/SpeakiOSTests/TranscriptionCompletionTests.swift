#if os(iOS) && DEBUG && targetEnvironment(simulator)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class TranscriptionCompletionTests: XCTestCase {
    func testClipboardWriteWithoutDeliveryConfirmation_RemainsNeutral() async throws {
        try await assertCompletion(destination: .clipboard, acceptsClipboardWrite: true)
    }

    func testDiscardedClipboardWrite_RemainsNeutral() async throws {
        try await assertCompletion(destination: .clipboard, acceptsClipboardWrite: false)
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

    private func assertCompletion(
        destination: HardwareTriggerDestination,
        saveToHistory: Bool = true,
        hasPolisher: Bool = false,
        acceptsClipboardWrite: Bool = true
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
        let pasteboard = CompletionTestPasteboard(acceptsWrites: acceptsClipboardWrite)
        var outcomes: [TranscriptionCompletionOutcome] = []
        var textAtCompletion: String?
        let service = TranscriptionRecordingService(
            sharedState: sharedState,
            historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard),
            hasPolishingKey: { hasPolisher },
            polish: { _, _, _ in "Polished transcript" },
            completeActivity: { count, _, _, outcome in
                XCTAssertEqual(count, 2)
                textAtCompletion = pasteboard.string
                outcomes.append(outcome)
            }
        )
        defaults.set("Raw transcript", forKey: "simulatorValidationTranscript")
        try await service.startRecording(sharesLiveTranscript: saveToHistory, requiresLiveActivity: false)
        let result = await service.stopRecording(destination: destination, saveToHistory: saveToHistory)
        XCTAssertEqual(result.text, "Raw transcript")
        XCTAssertEqual(outcomes, [.ready])
        let expectedClipboard = destination == .historyOnly || !acceptsClipboardWrite ? nil : "Raw transcript"
        XCTAssertEqual(textAtCompletion, expectedClipboard)
        XCTAssertEqual(history.items.count, saveToHistory ? 1 : 0)
        for _ in 0..<1_000 where !history.reprocessingIDs.isEmpty { await Task.yield() }
        XCTAssertEqual(outcomes, [.ready], "Polish must not schedule another completion UI update")
        XCTAssertEqual(pasteboard.writes, destination == .historyOnly ? [] : ["Raw transcript"])
        XCTAssertEqual(pasteboard.string, expectedClipboard, "Polish must never rewrite the clipboard")
        service.cancelRecording()
    }
}

@MainActor
private final class CompletionTestPasteboard: PolishPasteboard {
    let acceptsWrites: Bool
    var writes: [String] = []
    var string: String?

    init(acceptsWrites: Bool) {
        self.acceptsWrites = acceptsWrites
    }

    func write(_ text: String) {
        writes.append(text)
        if acceptsWrites { string = text }
    }
}
#endif
