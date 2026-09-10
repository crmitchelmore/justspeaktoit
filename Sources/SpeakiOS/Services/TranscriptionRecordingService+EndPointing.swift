#if os(iOS)
import Foundation
import SpeakCore
import UIKit

// Silence end-pointing for headless captures (issue #1012): the wiring between
// the microphone level and `CaptureEndPointingMonitor`. Every rule about *when*
// to stop lives in SpeakCore and is tested on the host; this file only samples,
// forwards and stops.

extension TranscriptionRecordingService {
    /// Arms end-pointing for the capture `session` owns.
    ///
    /// The session is the run's identity. Everything below re-checks that the
    /// session it armed for is still the service's session before it acts, the
    /// same guard `onPartialResult` and `onError` use, so a monitor belonging to
    /// a capture the user already stopped can never reach in and stop the one
    /// that replaced it (issue #943).
    /// A `nil` request arms nothing, so the caller does not need a branch of
    /// its own: a capture with no end-pointing runs exactly as it always did.
    func armEndPointing(_ request: CaptureEndPointingRequest?, for session: IOSTranscriptionSession) {
        disarmEndPointing()
        guard let request else { return }
        session.resetInputLevel()
        SpeakLogger.transcription.info(
            "End-pointing armed: \(request.logDescription, privacy: .public)"
        )
        // Monotonic, not wall clock. The maximum duration exists so a failed
        // detector cannot leave the microphone open; measuring it with `Date`
        // meant a backward clock correction reduced the observed elapsed time
        // and deferred the cap until the wall clock caught up. `ContinuousClock`
        // cannot be moved and keeps counting while the device is asleep, which
        // is the direction that keeps the cap honest.
        let startedAt = ContinuousClock.now
        endPointingTask = Task { [weak self, weak session] in
            var monitor = CaptureEndPointingMonitor(request)
            // Carried between samples so a level that has stopped being
            // refreshed is not counted as new silence: no new buffer means no
            // new evidence, not evidence of quiet. The elapsed clock still
            // advances, so the maximum-duration cap still fires either way.
            var lastObservedSequence: UInt64?
            var speechDetected = false
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(CaptureEndPointingPolicy.sampleIntervalSeconds * 1_000_000_000)
                )
                guard !Task.isCancelled, let self, let session,
                      self.ownsEndPointedSession(session) else { return }
                let sample = session.inputLevelSample
                if sample.sequence != lastObservedSequence {
                    lastObservedSequence = sample.sequence
                    speechDetected = CaptureEndPointingPolicy.speechDetected(levelDBFS: sample.levelDBFS)
                }
                let decision = monitor.observe(
                    speechDetected: speechDetected,
                    atSeconds: MonotonicClock.elapsedSeconds(since: startedAt)
                )
                switch decision {
                case .waiting:
                    continue
                case .warning:
                    self.cueImminentEndPointing()
                case .stop(let reason):
                    await self.endPoint(session, reason: reason)
                    return
                }
            }
        }
    }

    /// Cancels any armed monitor. Safe to call when nothing is armed, and
    /// called from every stop and cancel path so a monitor never outlives the
    /// capture it belongs to.
    func disarmEndPointing() {
        endPointingTask?.cancel()
        endPointingTask = nil
    }

    /// Whether the armed capture is still the one running.
    private func ownsEndPointedSession(_ session: IOSTranscriptionSession) -> Bool {
        transcriptionSession === session && state == .recording
    }

    /// Finishes the capture through the ordinary stop.
    ///
    /// `stopRecording` is the controlled-stop path every other surface uses, so
    /// an auto-stop finalises the transcript, honours the run's destination and
    /// writes History exactly as a press of the Live Activity button would.
    /// Nothing here is a second way to end a recording — it is the same one,
    /// called by a timer instead of a thumb. Its own reentrancy guard makes a
    /// race with a real stop a no-op rather than a second history entry.
    private func endPoint(_ session: IOSTranscriptionSession, reason: CaptureEndPointingStopReason) async {
        guard ownsEndPointedSession(session) else { return }
        SpeakLogger.transcription.info(
            "Capture end-pointed: \(reason.rawValue, privacy: .public)"
        )
        endPointingTask = nil
        await stopRecording(destination: resolvedStopDestination())
    }

    /// A soft haptic a second before the capture ends itself.
    ///
    /// Best effort, and only in the foreground: the platform does not play
    /// haptics for a backgrounded app, which is exactly the headless case this
    /// feature is for. It is a courtesy when the app happens to be open, not
    /// the safeguard against being cut off — the silence window, the
    /// speech-first rule and the setting being off by default are.
    private func cueImminentEndPointing() {
        guard UIApplication.shared.applicationState == .active else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// The end-pointing a capture should be armed with, or `nil` to leave it
    /// running until somebody stops it.
    ///
    /// Precedence matches every other per-run parameter: what the caller asked
    /// for wins, then the setting. The setting is deliberately narrow — it
    /// applies to headless triggers only. A keyboard hand-off is excluded
    /// because the keyboard owns its own end of the dictation, and an in-app
    /// capture is excluded because the user is looking at a stop button.
    static func endPointingRequest(
        explicit: CaptureEndPointingRequest?,
        trigger: CaptureTrigger?,
        keyboardProfile: KeyboardDictationProfileOption?,
        settings: AppSettings
    ) -> CaptureEndPointingRequest? {
        if let explicit { return keyboardProfile == nil ? explicit : nil }
        guard keyboardProfile == nil,
              settings.autoStopOnSilenceEnabled,
              trigger == .control || trigger == .shortcut
        else { return nil }
        return CaptureEndPointingRequest(silenceWindow: settings.autoStopSilenceSeconds)
    }
}
#endif
