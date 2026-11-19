#if os(iOS)
import Foundation
import SpeakCore

/// Failure reporting for the headless capture service: per-run request
/// diagnostics, the issue snapshot staged for the next published failure, and
/// the capture outcome journal the health screen reads (issue #997).
@MainActor
struct CaptureHealthReporter {
    var requests = IOSRequestDiagnosticState()
    private var pendingIssueFailure: IOSIssueReportSnapshot?
    private let journalDefaults: @MainActor () -> UserDefaults?

    init(journalDefaults: @escaping @MainActor () -> UserDefaults?) {
        self.journalDefaults = journalDefaults
    }

    /// Freezes the run's request diagnostics for the failure about to be
    /// published. A cancellation is not a reportable failure and stages none.
    mutating func stageFailure(_ error: Error, failure: RequestDiagnosticContext.Failure, run: UUID?) {
        pendingIssueFailure = error is CancellationError ? nil : requests.freezeFailure(failure, run: run)
    }

    /// Publishes the staged snapshot under a fresh token for a non-nil error.
    ///
    /// Every publication gets a fresh identity, including one that repeats an
    /// earlier failure word for word — a presenter that de-duplicated on the
    /// message would swallow the later one, with no intervening `nil` to tell
    /// the two apart (#1084).
    mutating func publishSessionError(_ error: Error?) -> UUID? {
        let token = error == nil ? nil : UUID()
        requests.publish(pendingIssueFailure, token: token)
        pendingIssueFailure = nil
        return token
    }

    func snapshot(for token: UUID?) -> IOSIssueReportSnapshot {
        requests.snapshot(for: token)
    }

    /// Records how a capture ended. The journal keeps a closed-set label, a
    /// local diagnostic code and a date — never the error's text.
    func journal(_ outcome: CaptureHealthLastOutcome, failure: Error?) {
        CaptureOutcomeJournal.record(outcome, failure: failure, defaults: journalDefaults())
    }

    func journal(failure: Error) {
        journal(CaptureOutcomeJournal.outcome(for: failure), failure: failure)
    }
}
#endif
