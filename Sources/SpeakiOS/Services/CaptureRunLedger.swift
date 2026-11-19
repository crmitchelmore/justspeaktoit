import Foundation

/// The headless capture's run identity and the transcript that run committed.
///
/// A waiter cannot read "the last completed transcript" and assume it is its
/// own: a stop leaves `recording` for `stopping` before it drains the session,
/// so a poll on liveness can return while finalisation is still running, and
/// an untagged slot would then hand back the *previous* capture's text.
/// Tagging also lets an empty result stay empty instead of being satisfied by
/// an older non-empty one.
struct CaptureRunLedger {
    struct Completion: Equatable {
        let runID: UUID
        let text: String
    }

    /// Identity of the capture in flight, so a caller that started one can
    /// recognise its own result. `nil` once that capture has settled.
    private(set) var currentRunID: UUID?
    /// The transcript the most recent capture committed, tagged with its run.
    private(set) var lastCompletion: Completion?

    /// Claims `runID` as the capture in flight.
    mutating func begin(_ runID: UUID) {
        currentRunID = runID
    }

    /// Commits `text` for the capture in flight and retires its identity.
    ///
    /// - Returns: the retired run, or `nil` when nothing was in flight. A second
    ///   completion is therefore a no-op and cannot overwrite the first.
    @discardableResult
    mutating func complete(with text: String) -> UUID? {
        guard let runID = currentRunID else { return nil }
        lastCompletion = Completion(runID: runID, text: text)
        currentRunID = nil
        return runID
    }

    /// The transcript `runID` committed, or `nil` when that capture has not
    /// completed (or a different one did). An empty string is a real answer.
    func completedTranscript(forRun runID: UUID) -> String? {
        guard let lastCompletion, lastCompletion.runID == runID else { return nil }
        return lastCompletion.text
    }
}
