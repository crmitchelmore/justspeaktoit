#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Callbacks from the live recording session: partial results, first input,
/// startup observations, warnings and mid-session errors, each accepted only
/// for the run that installed it.
@MainActor
extension TranscriptionRecordingService {
    func handlePartialResult(text: String) {
        partialText = text

        // App Group writes (plist + cfprefsd IPC) and word counting are O(n)
        // per partial; throttle them to ~1/s, mirroring the Live Activity
        // manager's own update throttle. The full transcript is committed
        // once more at stop.
        let now = Date()
        if now.timeIntervalSince(lastSharedStateWriteAt) >= Self.sharedStateWriteInterval {
            lastSharedStateWriteAt = now
            wordCount = text.split(separator: " ").count
            if sharesLiveTranscript {
                sharedState.updateTranscript(text)
            }
        }

        // Presentation only: the transcript above is delivered either way. A
        // partial can arrive from pre-roll before this run has seen its own
        // input, and it must not announce active capture (issue #983).
        guard presentation.isPresentingCapture else {
            publishPreparingActivity()
            return
        }
        activityManager.updateActivity(
            status: .listening,
            lastSnippet: sharesLiveTranscript ? text : "",
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    /// Wires this run to the session's existing observation boundary, and
    /// labels the backend when routing already settled it (issue #972).
    func bindStartupDiagnostics(session: any IOSRecordingSession, runID: UUID) {
        session.onStartupObservation = { [weak self] observation in
            self?.diagnostics.note(observation, run: runID)
            // Same seam, not a second one: the watchdogs' start deadline and
            // no-audio detector are driven by the boundaries issue #972
            // already reports (issue #993).
            if case .stage(let stage) = observation {
                self?.noteWatchdogStage(stage, run: runID)
            }
        }
        if let backend = session.resolution.resolvedStartupBackend {
            diagnostics.note(.backend(backend), run: runID)
        }
    }

    /// The measured boundary is the first *live* partial: a final result is a
    /// delivery, not evidence that streaming began.
    func noteFirstLivePartial(text: String, isFinal: Bool, runID: UUID) {
        guard !isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        diagnostics.noteFirstPartial(run: runID)
    }

    /// Explicitly synthetic: the DEBUG simulator stub has no audio session, no
    /// engine and no measured engine start.
    func noteSimulatorStubStartup(runID: UUID) {
        diagnostics.note(.backend(.simulatorStub), run: runID)
        diagnostics.finish(.started, run: runID)
    }

    func outcome(for error: Error) -> StartupOutcome {
        (error is CancellationError || Task.isCancelled) ? .cancelled : .failed
    }

    /// Routes this run's own first live buffer into the presentation gate.
    func bindFirstInput(session: any IOSRecordingSession, runID: UUID) {
        session.onFirstInputBuffer = { [weak self, weak session] in
            guard let self, let session,
                  self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
            else { return }
            self.notePresentation(self.presentation.noteInputObserved(run: runID))
            // The no-audio detector consumes issue #983's first-input signal
            // rather than installing a tap of its own (issue #993).
            self.noteWatchdogInputObserved(run: runID)
        }
    }

    /// Publishes the one arming → recording transition, and only that one.
    func notePresentation(_ promoted: Bool) {
        guard promoted else { return }
        activityManager.updateActivity(
            status: .recording,
            lastSnippet: sharesLiveTranscript ? partialText : "",
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    /// Keeps preparation truthful: no snippet, no elapsed time, no recording
    /// indicator until this run's own tap has delivered.
    func publishPreparingActivity() {
        activityManager.updateActivity(
            status: .arming,
            lastSnippet: CapturePresentationGate.preparingMessage,
            wordCount: 0,
            duration: 0
        )
    }

    func handleError(_ error: Error, session: any IOSRecordingSession) {
        // A mid-session failure previously only updated the Live Activity —
        // the mic stayed hot while the user dictated into a dead session.
        // Tear the session down, preserving the accumulated transcript, and
        // publish the error so the app can surface it on next foreground.
        guard lifecycle.state == .recording || stoppingSession === session else { return }
        // An audio interruption is a controlled stop, not a failure (issue
        // #936): it becomes a stopped notice and never a deferred error alert.
        // Anything else is a real provider or finalisation failure and stays
        // visible through `lastSessionError`, whose observer stamps the token.
        if (error as? iOSTranscriptionError)?.isControlledInterruption == true {
            captureStopNotice = error.localizedDescription
        } else {
            publishRequestFailure(error, failure: .init(stage: .request))
            activityManager.reportClassifiedError(error)
        }
        guard lifecycle.state == .recording else { return }
        Task { [weak self] in
            guard let self, self.isRunning, self.transcriptionSession === session else { return }
            // An interruption must still honour the destination the user chose
            // (issues #1008 and #1013): `automaticStopDestination` is the
            // internal destination, then the run's override, then the global
            // setting — never a bare `.clipboard`. This supersedes the
            // `resolvedStopDestination()` fix made on #1076, which was the same
            // rule expressed on the older shape of this path.
            await self.finishCaptureAfterDisruption()
        }
    }

    /// Finishes through the originating owner, which may own a keyboard nonce
    /// rather than a clipboard destination. Stop's lifecycle guard claims once.
    func finishCaptureAfterDisruption(stoppedMessage: String = "Recording stopped") async {
        guard lifecycle.state == .recording else { return }
        if let finishOwnedCapture = onCaptureDisruption {
            await finishOwnedCapture()
            return
        }
        await stopRecording(
            selection: resolvedStopSelection(),
            primedActivityMessage: lastSessionError?.localizedDescription ?? stoppedMessage
        )
    }

    /// Routes the run's one nonfatal loss notice to the published warning. The
    /// first notice may arrive while `start()` is still suspended, before
    /// `transcriptionSession` is assigned, so the starting run is accepted on
    /// the same terms as `onError` (issue #950).
    func bindRecordingWarning(_ session: any IOSRecordingSession, runID: UUID) {
        session.onRecordingWarning = { [weak self, weak session] message in
            guard let self, let session,
                  self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
            else { return }
            self.recordingWarning = message
        }
    }
}
#endif
