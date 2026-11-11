#if os(iOS)
import Foundation
import SpeakCore

/// How a stopping foreground session becomes a delivered capture: its bounded
/// drain, then the App Group transcript the copy intents read, onboarding
/// progress, History, and the offline-upgrade queue (issue #999) when the run
/// fell back to on-device recognition.
@MainActor
final class ForegroundCaptureFinalisation {
    private let sharedState: SharedTranscriptionState
    private let historyManager: iOSHistoryManager
    /// Queues an offline on-device capture for a cloud upgrade.
    var tagOfflineCapture: (iOSHistoryItem, UUID, String) -> Void = {
        OfflineTranscriptUpgrader.shared.tag(item: $0, recordingID: $1, intendedModelID: $2)
    }

    init(sharedState: SharedTranscriptionState, historyManager: iOSHistoryManager) {
        self.sharedState = sharedState
        self.historyManager = historyManager
    }

    /// How a stop's drain ended.
    enum Settlement {
        /// This stop no longer owns the outcome, or a failed explicit stop keeps nothing.
        case abandoned
        /// Cancel arrived during the drain: the utterance is discarded, not published.
        case discarded(TranscriptionResult)
        /// The transcript to publish and deliver.
        case finished(TranscriptionResult)
    }

    /// Drains `session` and decides what its stop delivers.
    ///
    /// - Parameters:
    ///   - stillOwned: whether this stop still owns the session (#943).
    ///   - shown: the transcript shown so far, read after the drain.
    ///   - onFailure: reports a failed drain and returns whether the shown
    ///     transcript is kept: a hands-free drain failure keeps the same
    ///     shared/History outcome as Stop (#942), and so does a capture the user
    ///     did not end (#936).
    static func settle(
        _ session: any IOSRecordingSession,
        handsFree: Bool,
        stillOwned: () -> Bool,
        shown: () -> TranscriptionResult,
        onFailure: (Error) -> Bool
    ) async -> Settlement {
        let drained: TranscriptionResult
        do {
            drained = try await drain(session, handsFree: handsFree)
        } catch {
            // A drain that failed leaves capture to unwind; ownership is held
            // until the provider's own cleanup has settled, so no replacement
            // can overlap this one (#943).
            session.cancel()
            await session.awaitCancellationSettled()
            guard stillOwned(), onFailure(error) else { return .abandoned }
            drained = shown()
        }
        let result = drained.replacingText(TranscriptionRecordingService.bestTranscript(
            candidates: [drained.text, shown().text], fallback: ""
        ))
        guard stillOwned() else {
            // The claim is held until the provider has finished cleaning up (#943).
            await session.awaitCancellationSettled()
            return .discarded(result)
        }
        return .finished(result)
    }

    /// The hands-free lane bounds its drain and cancels capture on timeout.
    static func drain(_ session: any IOSRecordingSession, handsFree: Bool) async throws -> TranscriptionResult {
        guard handsFree else { return try await session.stop() }
        return try await HandsFreeCaptureFinalisation(timeout: .seconds(session.stopCompletionTimeout)).run {
            try await session.stop()
        } cancelCapture: {
            session.onPartialResult = nil
            session.onError = nil
            session.cancel()
        }
    }

    func deliver(
        _ result: TranscriptionResult, model: String, errorMessage: String?,
        offlineIntendedModel: String?, recordingID: UUID?
    ) async {
        // Live shared-state writes are throttled; commit the final transcript
        // once so the copy intents always see the complete text.
        sharedState.updateTranscript(result.text)
        // Onboarding progress is only ever earned by a transcript that really
        // arrived; a blank one is ignored by the policy.
        CaptureOnboardingStore.shared.recordDictation(trigger: .inApp, transcript: result.text)
        let item = await historyManager.recordTranscriptionAndWait(
            text: result.text, model: model, duration: result.duration, errorMessage: errorMessage
        )
        if let item, let offlineIntendedModel, let recordingID {
            tagOfflineCapture(item, recordingID, offlineIntendedModel)
        }
    }
}
#endif
