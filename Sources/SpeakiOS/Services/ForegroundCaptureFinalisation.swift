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
    /// Settles a delivered capture's safety claim (issue #992).
    var markDelivered: (UUID) -> Void = { CaptureSafetyClaimStore.shared.markDelivered(recording: $0) }

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

        var discarded: TranscriptionResult? {
            if case .discarded(let result) = self { return result }
            return nil
        }
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

    /// Whether a provider error should finalise through the owner rather than
    /// surface as a bare failure: interruption and microphone change (#936),
    /// and a pre-ready startup overflow, which stops once (#949).
    static func requiresControlledStop(_ error: Error) -> Bool {
        if (error as? iOSTranscriptionError)?.endsCapture == true { return true }
        if case OpenAIRealtimeError.preReadyAudioOverflow = error { return true }
        return false
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

    /// Delivers a finished run's result. Its loss summary, joined with any
    /// published error, becomes the History entry's error message.
    func deliver(
        _ result: TranscriptionResult, from session: any IOSRecordingSession, model: String,
        error publishedError: Error?, offlineIntendedModel: String?
    ) async {
        let errorMessage = session.recordingLossSummary.map {
            [$0, publishedError?.localizedDescription].compactMap { $0 }.joined(separator: " ")
        }
        let recordingID = session.safetyRecordingID
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
        // The transcript has landed, so this capture's safety audio no longer
        // needs recovering. Without this every in-app recording was offered
        // back as "interrupted" on the next launch (issue #1617). A History
        // write that failed for real words leaves the claim open, so the audio
        // is still offered; an empty result has nothing to recover.
        if let recordingID, item != nil || result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markDelivered(recordingID)
        }
    }
}

extension TranscriptionResult {
    /// A foreground run's shown text as its result.
    static func shown(_ text: String, confidence: Double?, duration: Int, model: String) -> Self {
        TranscriptionResult(text: text, segments: [], confidence: confidence, duration: TimeInterval(duration),
                            modelIdentifier: model, cost: nil, rawPayload: nil, debugInfo: nil)
    }
}
#endif
