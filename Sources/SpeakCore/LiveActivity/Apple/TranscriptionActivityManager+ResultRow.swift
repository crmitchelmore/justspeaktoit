import Foundation

#if os(iOS)
import ActivityKit

// MARK: - Result Row

/// The finished-capture row's own API: the neutral completion entry point and
/// the confirmed Copy from the row itself. Both name the completion they
/// belong to, because the activity outlives any one session; the lifecycle
/// rules that decide whether a write may still land live with the manager.
extension TranscriptionActivityManager {
    /// Marks the activity as completed. Headless recordings keep it primed so
    /// the next Action Button invocation can start entirely in the background.
    ///
    /// `completionMessage` is the capture receipt (issue #1008): what the
    /// transcript's delivery actually did, built from observed results. When
    /// none is supplied the row keeps its neutral "Transcription ready".
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle,
        completionMessage: String? = nil
    ) {
        completeActivity(
            finalWordCount: finalWordCount,
            duration: duration,
            keepPrimed: keepPrimed,
            primedMessage: primedMessage,
            primedStatus: primedStatus,
            completionOutcome: .ready,
            resultPreview: "",
            completionMessage: completionMessage,
            resultCompletionID: ""
        )
    }

    /// Explicit outcome variant; the original entry point remains neutral and source-compatible.
    ///
    /// The completed row stays on screen for `resultRowDuration`. A primed
    /// activity then returns to its idle label — unless a new recording has
    /// taken the activity over in the meantime, in which case the reset was
    /// superseded and never publishes.
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle,
        completionOutcome: TranscriptionCompletionOutcome,
        resultPreview: String = "",
        completionMessage: String? = nil,
        resultCompletionID: String = ""
    ) {
        complete(TranscriptionActivityCompletion(
            finalWordCount: finalWordCount, duration: duration, keepPrimed: keepPrimed,
            primedMessage: primedMessage, primedStatus: primedStatus, outcome: completionOutcome,
            resultPreview: resultPreview, message: completionMessage, resultCompletionID: resultCompletionID
        ), owner: nil)
    }

    /// Associates only the retained active result surface with an in-process owner.
    /// This identity is never encoded in Activity content or used to retrieve a transcript.
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle,
        completionOutcome: TranscriptionCompletionOutcome,
        resultPreview: String = "",
        completionMessage: String? = nil,
        resultCompletionID: String = "",
        surfaceOwnerID: UUID
    ) {
        complete(TranscriptionActivityCompletion(
            finalWordCount: finalWordCount, duration: duration, keepPrimed: keepPrimed,
            primedMessage: primedMessage, primedStatus: primedStatus, outcome: completionOutcome,
            resultPreview: resultPreview, message: completionMessage, resultCompletionID: resultCompletionID
        ), owner: surfaceOwnerID)
    }

    /// Records a *confirmed* clipboard write on the result row. Only the Copy
    /// action calls this, and only after reading back `UIPasteboard.changeCount`,
    /// so `.copied` on screen always corresponds to a write that actually landed.
    ///
    /// `completionID` is the id the tapped row carried. The update is applied only
    /// while the activity's latest submitted state is still that completion, so a
    /// Copy from a row that is still on screen after a newer session has taken
    /// the activity over leaves the newer state alone rather than relabelling it.
    ///
    /// Returns whether the row could be updated. `false` is normal rather than a
    /// failure: the non-primed path ends the activity as soon as it completes,
    /// and ActivityKit does not accept updates to an ended activity, so for those
    /// rows the intent's own confirmation is the only receipt available.
    @discardableResult
    public func markCompletionCopied(completionID: String) async -> Bool {
        guard let activity, activity.activityState == .active else { return false }
        var state = latestState ?? activity.transcriptionState
        guard state.status == .completed, state.completionOutcome != .noSpeech else { return false }
        guard !completionID.isEmpty, state.resultCompletionID == completionID else { return false }
        state.completionOutcome = .copied
        state.lastSnippet = TranscriptionCompletionOutcome.copied.message
        enqueueUpdate(state, activity: activity, runID: runID)
        return true
    }
}
#endif
