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
        let history = Self.historyManager(in: directory, defaults: defaults)
        let pasteboard = CompletionTestPasteboard(acceptsWrites: acceptsClipboardWrite)
        let completions = CompletionRecorder()
        var textAtCompletion: String?
        let service = TranscriptionRecordingService(
            sharedState: sharedState,
            historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard),
            hasPolishingKey: { hasPolisher },
            polish: { _, _, _ in "Polished transcript" },
            completeActivity: { count, _, _, outcome, preview, _, completionID in
                XCTAssertEqual(count, 2)
                textAtCompletion = pasteboard.string
                completions.record(outcome: outcome, preview: preview, completionID: completionID)
            }
        )
        defaults.set("Raw transcript", forKey: "simulatorValidationTranscript")
        try await service.startRecording(sharesLiveTranscript: saveToHistory, requiresLiveActivity: false)
        let result = await service.stopRecording(destination: destination, saveToHistory: saveToHistory)
        XCTAssertEqual(result.text, "Raw transcript")
        XCTAssertEqual(completions.outcomes, [.ready])
        let expectedClipboard = destination == .historyOnly || !acceptsClipboardWrite ? nil : "Raw transcript"
        XCTAssertEqual(textAtCompletion, expectedClipboard)
        XCTAssertEqual(history.items.count, saveToHistory ? 1 : 0)
        for _ in 0..<1_000 where !history.reprocessingIDs.isEmpty { await Task.yield() }
        XCTAssertEqual(
            completions.outcomes, [.ready], "Polish must not schedule another completion UI update"
        )
        XCTAssertEqual(pasteboard.writes, destination == .historyOnly ? [] : ["Raw transcript"])
        XCTAssertEqual(pasteboard.string, expectedClipboard, "Polish must never rewrite the clipboard")
        XCTAssertEqual(
            completions.previews,
            [saveToHistory ? "Raw transcript" : ""],
            "Only a published transcript may carry a preview, which is what enables the result row's actions"
        )
        try assertCompletionIsAddressable(
            try XCTUnwrap(completions.ids.first), sharedState: sharedState, published: saveToHistory
        )
        service.cancelRecording()
    }

    private static func historyManager(in directory: URL, defaults: UserDefaults) -> iOSHistoryManager {
        iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"),
            syncEnabled: false,
            userDefaults: defaults
        )
    }

    /// The row's Copy action addresses one completion. A published transcript
    /// must therefore be stamped with the id the row carries, and the App Group
    /// must hand that text back only for that id — a row that cannot name its
    /// completion offers no Copy at all.
    private func assertCompletionIsAddressable(
        _ completionID: String,
        sharedState: SharedTranscriptionState,
        published: Bool
    ) throws {
        guard published else {
            XCTAssertTrue(
                completionID.isEmpty,
                "A keyboard handoff publishes nothing retrievable, so its row must not claim a completion"
            )
            XCTAssertNil(sharedState.completedTranscript(matching: ""))
            return
        }
        XCTAssertFalse(completionID.isEmpty, "A published transcript must name its completion")
        XCTAssertEqual(sharedState.completedTranscriptID, completionID)
        // Post-processing rewrites the text under the same id, so whatever the
        // App Group ends up holding stays reachable from the row that produced
        // it — the id addresses the completion, not one particular string.
        XCTAssertEqual(
            sharedState.completedTranscript(matching: completionID),
            sharedState.lastCompletedTranscript,
            "The row's own completion must resolve to the transcript it published"
        )
        XCTAssertNotNil(sharedState.completedTranscript(matching: completionID))
        XCTAssertNil(
            sharedState.completedTranscript(matching: UUID().uuidString),
            "A different completion's id must never resolve to this transcript"
        )
    }
}

/// What each completion told the Live Activity, in order.
@MainActor
private final class CompletionRecorder {
    private(set) var outcomes: [TranscriptionCompletionOutcome] = []
    private(set) var previews: [String] = []
    private(set) var ids: [String] = []

    func record(outcome: TranscriptionCompletionOutcome, preview: String, completionID: String) {
        outcomes.append(outcome)
        previews.append(preview)
        ids.append(completionID)
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
