#if os(iOS)
import Foundation
import SpeakCore

/// What the foreground coordinator observes about one run: truthful capture
/// presentation (issue #983), local startup timing (issue #972) and the
/// request diagnostics an issue report freezes. All three are keyed by the
/// lifecycle's run identity, so none can attribute work to another run.
/// Measurement and presentation only: nothing here changes capture.
@MainActor
final class ForegroundRunObservation {
    private var presentation = CapturePresentationGate()
    private var presentationRunID: UUID?
    private var startup = StartupDiagnostics()
    private var requests = IOSRequestDiagnosticState()

    /// Whether active-capture presentation may be shown for the current run.
    var isPresentingCapture: Bool { presentation.isPresentingCapture }

    func begin(_ runID: UUID, entry: StartupEntry?) {
        requests.begin(runID)
        presentationRunID = runID
        presentation.begin(run: runID)
        startup.begin(run: runID, entry: entry, localOrigin: .coordinator)
    }

    // MARK: Presentation

    /// Each returns whether this run has just been promoted to active capture.
    @discardableResult
    func noteBackendStarted(_ runID: UUID) -> Bool { presentation.noteBackendStarted(run: runID) }
    func noteInputObserved(_ runID: UUID) -> Bool { presentation.noteInputObserved(run: runID) }

    /// Ends the run's presentation: stop, cancel, or a failed start. A run
    /// that never saw input resolves to a terminal state, not to permanent
    /// preparation. Returns `false` when no run was presenting.
    func finishPresentation() -> Bool {
        guard presentationRunID != nil else { return false }
        presentationRunID = nil
        presentation.finish()
        // A late partial cannot report against a run that is over.
        startup.retire()
        return true
    }

    // MARK: Startup timing

    func note(_ observation: StartupObservation, run runID: UUID) {
        startup.note(observation, run: runID)
    }

    func noteStarted(_ runID: UUID) {
        startup.finish(.started, run: runID)
    }

    /// Wires this run to the session's observation boundary, and labels the
    /// backend when routing already settled it.
    func bindStartup(of session: any IOSRecordingSession, run runID: UUID) {
        session.onStartupObservation = { [weak self] observation in
            self?.startup.note(observation, run: runID)
        }
        if let backend = session.resolution.resolvedStartupBackend {
            startup.note(.backend(backend), run: runID)
        }
    }

    /// The measured boundary is the first *live* partial: a final result is a
    /// delivery, not evidence that streaming began.
    func noteFirstLivePartial(text: String, isFinal: Bool, run runID: UUID) {
        guard !isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        startup.noteFirstPartial(run: runID)
    }

    /// A start that stopped short still reports what it did reach; the stages
    /// it never crossed stay absent rather than becoming zeroes.
    func finishStartup(_ runID: UUID, error: Error) {
        let cancelled = error is CancellationError || Task.isCancelled
        if cancelled {
            requests.discardFailure(runID)
        } else {
            // Still owned; freeze before presentation/run teardown clears state.
            requests.freezeFailure(.init(), run: runID)
        }
        startup.finish(cancelled ? .cancelled : .failed, run: runID)
    }

    /// Explicitly synthetic: the DEBUG simulator stub has no audio session, no
    /// engine and no measured engine start.
    func noteSimulatorStub(_ runID: UUID) {
        startup.note(.backend(.simulatorStub), run: runID)
        startup.finish(.started, run: runID)
    }

    // MARK: Request diagnostics

    func admitRequest(modelID: String, run runID: UUID) {
        requests.admit(IOSRequestDiagnosticProjection.foreground(modelID: modelID), run: runID)
    }

    func observe(_ resolution: IOSTranscriptionSession.Resolution, run runID: UUID, defaultSession: Bool) {
        requests.observe(resolution, run: runID, defaultSession: defaultSession)
    }

    func freezeRequestFailure(run runID: UUID?) -> IOSIssueReportSnapshot? {
        requests.freezeFailure(.init(stage: .request), run: runID)
    }

    func failedStartSnapshot(for runID: UUID?) -> IOSIssueReportSnapshot {
        requests.failedStartSnapshot(for: runID)
    }

    func retire(_ runID: UUID) {
        requests.retire(runID)
    }
}
#endif
