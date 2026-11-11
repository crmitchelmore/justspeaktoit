import Foundation

/// Which stop's completion may still publish, and which run's background
/// polish the service's published polish state describes (#1015).
///
/// One value owns all of it, so a stop that supersedes another replaces the
/// whole state at once: an older polish can neither answer a newer run's
/// waiter nor clear its in-progress flag, and a cancelled completion cannot
/// deliver.
struct CapturePolishLedger: Equatable {
    /// The stop whose completion may still deliver; `nil` once cancelled.
    private(set) var completionID: UUID?
    /// The run the polish state below belongs to.
    private(set) var polishingRunID: UUID?
    private(set) var isPostProcessing = false
    /// The current run's polished text, `nil` until (and unless) it lands.
    private(set) var polishedTranscript: String?

    /// Starts a stop's completion, superseding any earlier one.
    mutating func beginCompletion() -> UUID {
        let completionID = UUID()
        self.completionID = completionID
        return completionID
    }

    func isCurrent(_ completionID: UUID) -> Bool { self.completionID == completionID }

    /// Cancel during a stop: the completion in flight may no longer deliver.
    mutating func retireCompletion() { completionID = nil }

    /// A new stop supersedes whatever the previous one polished, then either
    /// starts its own polish or records that none runs.
    mutating func settlePolish(startingFor runID: UUID?, polishes: Bool) {
        polishedTranscript = nil
        isPostProcessing = polishes
        polishingRunID = polishes ? runID : nil
    }

    /// Only the current completion's polish may be waited on.
    mutating func recordPolished(_ text: String, completion completionID: UUID) {
        guard isCurrent(completionID) else { return }
        polishedTranscript = text
    }

    /// Only the run that still owns the polish may release its waiter.
    mutating func finishPolish(run runID: UUID?) {
        guard polishingRunID == runID else { return }
        isPostProcessing = false
    }

    /// Whether `runID` still owns a polish that has not finished.
    func isPolishing(run runID: UUID) -> Bool { isPostProcessing && polishingRunID == runID }

    /// What `runID`'s finished polish produced; `nil` while it runs, when it
    /// failed or produced nothing, or once a newer stop owns the state.
    func polishedTranscript(forRun runID: UUID) -> String? {
        guard polishingRunID == runID, !isPostProcessing else { return nil }
        return polishedTranscript
    }
}
