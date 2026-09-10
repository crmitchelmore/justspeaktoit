import Foundation

#if os(iOS)
import ActivityKit

// MARK: - Result Row

/// The finished-capture row's own lifecycle: the two things that may change it —
/// a newer session taking the activity over, and a confirmed Copy from the row
/// itself. Both have to name the completion they belong to, because the activity
/// outlives any one session.
extension TranscriptionActivityManager {
    /// Retires the current result row: cancels its deferred reset and forgets
    /// which completion owned it, so nothing scheduled for it can still fire.
    func retireResultRow() {
        self.resultRowResetTask?.cancel()
        self.resultRowResetTask = nil
        self.resultRowToken = nil
    }

    /// Records a *confirmed* clipboard write on the result row. Only the Copy
    /// action calls this, and only after reading back `UIPasteboard.changeCount`,
    /// so `.copied` on screen always corresponds to a write that actually landed.
    ///
    /// `completionID` is the id the tapped row carried. The update is applied only
    /// when the activity is still showing that completion, so a Copy from a row
    /// that is still on screen after a newer session has taken the activity over
    /// leaves the newer state alone rather than relabelling it.
    ///
    /// Returns whether the row could be updated. `false` is normal rather than a
    /// failure: the non-primed path ends the activity as soon as it completes,
    /// and ActivityKit does not accept updates to an ended activity, so for those
    /// rows the intent's own confirmation is the only receipt available.
    @discardableResult
    public func markCompletionCopied(completionID: String) async -> Bool {
        guard let activity = currentActivity else { return false }
        var state = activity.content.state
        guard state.status == .completed, state.completionOutcome != .noSpeech else { return false }
        guard !completionID.isEmpty, state.resultCompletionID == completionID else { return false }
        state.completionOutcome = .copied
        state.lastSnippet = TranscriptionCompletionOutcome.copied.message
        await activity.update(.init(state: state, staleDate: nil))
        return true
    }
}
#endif
