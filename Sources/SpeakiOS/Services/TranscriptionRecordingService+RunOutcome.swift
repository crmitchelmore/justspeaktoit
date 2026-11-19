#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// How a run settles for the callers waiting on it: its identity, the
/// transcript it committed, the outcome it published and the failures it
/// journals. Each answer is tagged with its own run so a waiter can never
/// read an earlier or later capture's result.
@MainActor
extension TranscriptionRecordingService {
    /// Surfaces a refused capture link on the same alert path a failed session
    /// uses, so a link that does nothing says why. The caller is told through
    /// its `x-error` callback; this is the half the user can see.
    public func reportCaptureFailure(_ failure: Error) {
        lastSessionError = failure
        sessionErrorToken = UUID()
    }

    /// Settles the current session's outcome under its own identity and clears
    /// the identity, so nothing waiting on it can be answered twice or answered
    /// with a later recording's result.
    func publishFinishedCapture(text: String, failure: Error?) {
        guard let sessionID = currentSessionID else { return }
        currentSessionID = nil
        lastFinishedCapture = FinishedCapture(
            sessionID: sessionID,
            text: text,
            failureMessage: failure?.localizedDescription
        )
    }

    /// The transcript committed by a specific capture, tagged with its
    /// identity.
    public struct CaptureRunCompletion: Sendable, Equatable {
        public let runID: UUID
        public let text: String
    }

    /// Identity of the capture in flight, or `nil` when none is. A caller that
    /// starts a capture and then waits for it reads this immediately after
    /// `startRecording` returns and uses it to claim its own result.
    public var activeCaptureID: UUID? { currentRunID }

    /// Whether anything is still in flight — including a stop that is draining
    /// the transcriber and committing its result.
    ///
    /// `isActive` deliberately excludes `stopping`, because a stop has nothing
    /// left to act on. A *waiter* needs the wider question: a poll on
    /// `isActive` returns while finalisation is still running.
    public var isSettling: Bool { state != .idle }

    /// The transcript `runID` committed, or `nil` when that capture has not
    /// completed (or a different one did). An empty string is a real answer:
    /// the capture finished and produced no text.
    public func completedTranscript(forRun runID: UUID) -> String? {
        runLedger.completedTranscript(forRun: runID)
    }

    func retainStartupWatchdogFailure(_ error: iOSTranscriptionError, run: UUID) {
        guard currentRunID == run, lifecycle.isCurrentStartRun(run) else { return }
        startupWatchdogFailure = (run, error)
    }

    /// A final intent failure may only annotate its own failed, fully settled admission.
    /// A late framework error after a successful start cannot rewrite even that same run's result.
    func recordTerminalStartupFailure(
        _ error: Error,
        request: CaptureConfigurationRequest
    ) {
        guard !request.serviceStartReturnedNormally, let run = request.admittedRunID,
              state == .idle, !foregroundOwnership.isOwned, runLedger.lastCompletion?.runID == run else { return }
        let cause = startupWatchdogFailure.flatMap { $0.runID == run ? $0.error : nil }
        let failure: Error = (cause as Error?) ?? error
        health.journal(failure: failure)
    }

    /// A start intent refused its own Shortcut parameters before any admission,
    /// so the foreground helper never ran and nothing else journals the refusal.
    /// Recorded only while nothing is in flight or owned in the foreground, so a
    /// refused retry cannot overwrite a running or in-app capture's outcome.
    func recordRefusedStartParameters(_ failure: CaptureParameterFailure) {
        guard state == .idle, !foregroundOwnership.isOwned else { return }
        health.journal(.failed, failure: failure)
    }

    /// Publishes the result of the capture in flight, if there is one, and
    /// retires its identity.
    func completeRun(with text: String) {
        guard let retired = runLedger.complete(with: text) else { return }
        health.requests.retire(retired)
    }
}
#endif
