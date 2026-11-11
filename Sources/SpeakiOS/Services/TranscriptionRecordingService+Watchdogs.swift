#if os(iOS)
import Foundation
import SpeakCore

// Capture watchdogs (issue #993): the wiring between a live capture and
// `CaptureWatchdogHandle`. Every rule about *when* a bound has been exceeded,
// and the run-owned tick that checks it, lives in SpeakCore and is proved on
// the host; this file only arms and retires the handle, forwards the
// boundaries the run already reports, and routes each trip into the
// controlled path that already exists for that outcome.
//
// Nothing here is a new way to end a recording. A trip during startup retires
// the pending run through the same `stopRecording` a stop button press would
// (issue #701); a trip on a live capture goes through
// `finishCaptureAfterDisruption()`, which hands the capture back to whichever
// owner started it — the keyboard's nonce or the run's destination — exactly as
// issues #1032 and #1036 established.

extension TranscriptionRecordingService {
    /// Arms the bounds for `run`, retiring any previous run's watchdog work.
    ///
    /// The clock starts at the same instant the startup diagnostics' clock does
    /// — the earliest app-code entry the caller observed (issue #972) — so the
    /// start deadline measures what the user actually waited through, not just
    /// the part of it the service saw.
    func armWatchdogs(run: UUID, entry: StartupEntry?) {
        watchdog.arm(run: run, startedAt: entry?.observedAt ?? Date()) { [weak self] in
            self?.state == .starting || self?.state == .recording
        } onTrip: { [weak self] trip, run in
            await self?.act(on: trip, run: run)
        }
    }

    /// Retires the armed run's watchdog work. Called from every teardown path,
    /// so a watchdog can never outlive the run it belongs to and can never act
    /// on a run that has already ended.
    func disarmWatchdogs() {
        watchdog.retire()
    }

    /// Forwards a startup boundary from the existing observation seam.
    func noteWatchdogStage(_ stage: StartupStage, run: UUID) {
        watchdog.note(stage, run: run)
    }

    /// Forwards issue #983's first-input signal. A positive frame count proves
    /// the tap is delivering; it says nothing about whether anyone spoke, which
    /// is exactly why the no-audio detector can use it without ever firing on
    /// somebody who simply had not started talking yet.
    func noteWatchdogInputObserved(run: UUID) {
        watchdog.noteInputObserved(run: run)
    }

    /// Whether `run` is still the run these bounds belong to *and* is still in
    /// flight. Both halves matter: the first stops a watchdog terminating a
    /// newer run (issue #943), the second makes it a no-op once the run ended
    /// by any other route.
    private func ownsWatchdogRun(_ run: UUID) -> Bool {
        watchdog.owns(run) && (state == .starting || state == .recording)
    }

    private func act(on trip: CaptureWatchdogTrip, run: UUID) async {
        guard ownsWatchdogRun(run) else { return }
        switch trip {
        case .startStalled(let stage):
            SpeakLogger.transcription.error(
                "Capture watchdog: start stalled after \(stage?.rawValue ?? "no boundary", privacy: .public)"
            )
            await abandonStart(iOSTranscriptionError.startTimedOut(after: stage), run: run)
        case .noInput:
            SpeakLogger.transcription.error("Capture watchdog: the input tap delivered no buffer")
            await handleSilentMicrophone(run: run)
        case .maximumDurationWarning:
            // Not terminal: the handle keeps this run's tick running.
            publishMaximumDurationWarning(run: run)
        case .maximumDuration:
            SpeakLogger.transcription.info("Capture watchdog: capture reached its maximum duration")
            await finishCaptureAfterDisruption(
                stoppedMessage: "Recording stopped at its one-hour limit."
            )
        }
    }

    /// Ends a start that never got going.
    ///
    /// `stopRecording` during `starting` is the existing cancellable-startup
    /// path: it retires the run and waits for it to release everything it
    /// allocated. The error is published first so the app raises it on next
    /// foreground rather than leaving the user with a card that simply vanished.
    private func abandonStart(_ error: iOSTranscriptionError, run: UUID) async {
        guard state == .starting else { return }
        retainStartupWatchdogFailure(error, run: run)
        publishRequestFailure(error, failure: .init(stage: .admission, code: .timeout, domain: .application))
        await stopRecording(selection: resolvedStopSelection())
    }

    /// Ends a capture whose microphone is delivering nothing.
    ///
    /// A live capture is finished through its owner, so the words already
    /// transcribed are finalised, the destination is honoured and History is
    /// written. A start that has not gone live yet has nothing to finalise and
    /// is retired instead.
    private func handleSilentMicrophone(run: UUID) async {
        publishRequestFailure(
            iOSTranscriptionError.microphoneDeliveredNoAudio,
            failure: .init(stage: .request, code: .unavailable, domain: .application)
        )
        if state == .recording {
            await finishCaptureAfterDisruption(
                stoppedMessage: iOSTranscriptionError.microphoneDeliveredNoAudio.localizedDescription
            )
        } else if state == .starting {
            retainStartupWatchdogFailure(.microphoneDeliveredNoAudio, run: run)
            await stopRecording(selection: resolvedStopSelection())
        }
    }

    /// Says once, on the Live Activity, that the cap is coming.
    ///
    /// A user still talking at that point can stop and start again rather than
    /// being cut off without warning. If they are not talking — the pocket case
    /// this cap exists for — nothing overwrites the message and it is the last
    /// thing the card says before the capture finishes itself.
    private func publishMaximumDurationWarning(run: UUID) {
        guard state == .recording, let elapsed = watchdog.elapsedSeconds(for: run) else { return }
        let minutes = Int(
            (CaptureWatchdogPolicy.maximumCaptureWarningLeadSeconds / 60).rounded()
        )
        TranscriptionActivityManager.shared.updateActivity(
            status: .listening,
            lastSnippet: "Recording stops in \(minutes) minutes.",
            wordCount: wordCount,
            duration: Int(elapsed)
        )
    }
}

// MARK: - Bounded finalisation

extension TranscriptionRecordingService {
    /// Awaits the provider's finalisation, giving up after the budget for this
    /// backend.
    ///
    /// This is a ceiling over the shorter provider-level bounds that already
    /// exist — the legacy Apple recogniser's two-second completion wait from
    /// issue #948 among them — not a replacement for any of them. It exists for
    /// the case those cannot reach: a socket or an upload that never returns at
    /// all, which today leaves the stop suspended and the mic button dead
    /// indefinitely.
    ///
    /// - Returns: `nil` when the budget elapsed first.
    func boundedStop(of session: any IOSRecordingSession) async throws -> TranscriptionResult? {
        try await CaptureDeadline.result(
            of: { try await session.stop() },
            orNilAfter: CaptureWatchdogPolicy.finalisationDeadlineSeconds(isBatch: session.isBatch)
        )
    }

    /// What a stop returns when its provider never finalised.
    ///
    /// The text already received is kept, so a streaming capture that has been
    /// publishing partials loses nothing; a batch capture has no partials by
    /// design and this is honestly empty rather than fabricated. Either way the
    /// error is published, so the outcome is stated rather than presented as a
    /// successful stop with no words in it.
    func timedOutFinalisationResult(
        for session: any IOSRecordingSession,
        duration: Int
    ) -> TranscriptionResult {
        session.cancel()
        publishRequestFailure(
            iOSTranscriptionError.finalisationTimedOut,
            failure: .init(stage: .finalization, code: .timeout, domain: .application)
        )
        SpeakLogger.transcription.error(
            """
            Capture watchdog: finalisation exceeded \
            \(Int(CaptureWatchdogPolicy.finalisationDeadlineSeconds(isBatch: session.isBatch)), privacy: .public)s
            """
        )
        return TranscriptionResult(
            text: partialText,
            segments: [],
            confidence: nil,
            duration: TimeInterval(duration),
            modelIdentifier: session.resolution.modelID,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }
}
#endif
