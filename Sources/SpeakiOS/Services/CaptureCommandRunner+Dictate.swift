#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// `dictate`: the one capture verb that waits for its own result and hands it
/// back to the app that asked for it.
///
/// Split out of `CaptureCommandRunner` because it is the only verb that is not
/// a single call on the recorder — it starts a capture, decides when it is
/// over, collects that capture's own outcome, and answers an x-callback-url
/// caller — and because the returning half of the vocabulary is worth reading
/// on its own.
extension CaptureCommandRunner {
    // MARK: - dictate

    /// One-shot capture that returns its transcript to the caller.
    ///
    /// The refusal rules run before anything opens a microphone: locked device,
    /// app not foreground, or a capture already in flight. That last one is the
    /// existing single-flight rule (issue #943) — a `dictate` arriving mid
    /// recording is refused, never allowed to start a second session.
    static func dictate(_ link: CaptureDeepLink) async -> Bool {
        let service = TranscriptionRecordingService.shared
        if let refusal = CaptureLinkPolicy.refusal(
            isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            isAppActive: UIApplication.shared.applicationState == .active,
            isCaptureBusy: service.isActive || SharedTranscriptionState.shared.isRecording
        ) {
            self.report(refusal, to: link.callback)
            return false
        }

        let startOutcome = await self.start(
            service,
            destinationOverride: link.destination,
            modelOverride: link.modelIdentifier,
            languageOverride: link.languageIdentifier
        )
        switch startOutcome {
        case .started:
            break
        case .cancelled:
            // A stop retired this startup, which is the user getting what they
            // asked for. `x-cancel` is exactly this case in the
            // x-callback-url convention, and no alert is raised: telling
            // someone their cancellation failed is the contradiction the
            // cancellation policy exists to avoid.
            self.open(link.callback?.cancelURL, reason: "x-cancel")
            return false
        case .failed(let failure, let surfaced):
            // The specific reason reaches the caller's `x-error` — a `model=`
            // this device cannot honour says so rather than reporting a generic
            // failure. `notifyUser: !surfaced`: when the start already
            // published that reason, a second alert on top of it would be one
            // failure shown twice, and the vaguer of the two.
            self.report(failure, to: link.callback, notifyUser: !surfaced)
            return false
        }

        // Captured now, before anything can stop the capture: this is what ties
        // the result that comes back to the session this link started.
        guard let sessionID = service.currentSessionID else {
            self.report(.recordingFailed, to: link.callback)
            return false
        }

        let outcome = await self.awaitOutcome(
            service, sessionID: sessionID, maxDuration: link.dictateDuration
        )
        switch outcome {
        case .transcript(let text):
            self.deliver(text, to: link.callback)
            return true
        case .failed(let failure):
            self.report(failure, to: link.callback)
            return false
        }
    }

    /// How a dictation ended, as far as its caller is concerned.
    private enum DictateOutcome {
        /// The session finished. An empty string is a real answer — silence —
        /// and becomes `x-cancel`.
        case transcript(String)
        /// The session did not produce an answer. Becomes `x-error`, never a
        /// cancellation and never an empty success.
        case failed(CaptureLinkFailure)
    }

    /// Waits for *this* dictation to end, then produces its outcome.
    ///
    /// Three ways it ends, and all three resolve through the recorder's
    /// `lastFinishedCapture` rather than through any global "last transcript":
    ///
    /// * the deadline passes, and this stops the capture itself;
    /// * the app leaves the foreground, and this stops the capture itself —
    ///   `Task.sleep` does not run while the process is suspended, so the
    ///   deadline alone cannot bound a microphone across that transition, and
    ///   `dictate` is a foreground-only verb in the first place;
    /// * something else stops it (the Live Activity, the Action Button, a later
    ///   `justspeaktoit://stop`), in which case this waits for that session's
    ///   own result to settle.
    ///
    /// The last case is the one that used to read
    /// `SharedTranscriptionState.lastCompletedTranscript`: the recorder leaves
    /// `isActive` before it has drained and published, so that read could return
    /// the *previous* recording's text, or — if another capture finished in the
    /// interval — someone else's.
    private static func awaitOutcome(
        _ service: TranscriptionRecordingService,
        sessionID: UUID,
        maxDuration: TimeInterval
    ) async -> DictateOutcome {
        let deadline = Date().addingTimeInterval(maxDuration)
        let foreground = ForegroundWatch()
        defer { foreground.stop() }

        while service.isActive, Date() < deadline, !foreground.leftForeground {
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        if service.isActive {
            _ = await self.stop(service)
        }
        // Settlement is awaited either way. Owning the stop is not enough: a
        // stop that lands on the recorder's re-entrancy guard, or on a startup
        // still unwinding, returns an empty no-op result while the session that
        // is really finishing publishes a moment later.
        await self.awaitSettlement(of: sessionID, from: service)

        guard let finished = service.lastFinishedCapture, finished.sessionID == sessionID else {
            // The capture this link started never settled under its own
            // identity. Refusing is the only honest answer: the alternative is
            // handing back whatever text happens to be lying around.
            SpeakLogger.transcription.warning(
                "Dictate could not collect its own session's result"
            )
            return .failed(.transcriptionFailed)
        }
        if finished.failed {
            // A provider or recording error is not silence and not success.
            return .failed(.transcriptionFailed)
        }
        return .transcript(finished.text)
    }

    private static let pollInterval: UInt64 = 250_000_000

    /// Waits, bounded, for a session that something else stopped to publish its
    /// result. Draining a transcriber is not instant, and the recorder leaves
    /// `isActive` first.
    private static func awaitSettlement(
        of sessionID: UUID,
        from service: TranscriptionRecordingService
    ) async {
        let settlementDeadline = Date().addingTimeInterval(settlementGrace)
        while service.lastFinishedCapture?.sessionID != sessionID, Date() < settlementDeadline {
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    /// How long to wait for an externally stopped session to finish draining
    /// and publish. Generous enough for a batch upload to come back, short
    /// enough that a caller is not left waiting indefinitely.
    private static let settlementGrace: TimeInterval = 120

    /// Notices the app leaving the foreground while a dictation is in flight.
    ///
    /// `didEnterBackground` rather than `willResignActive`: a notification
    /// banner or Control Centre must not end someone's dictation, but a switch
    /// to another app suspends this process, and a suspended process cannot
    /// enforce the caller's `maxDuration` on the microphone it opened.
    @MainActor
    private final class ForegroundWatch {
        private(set) var leftForeground = false
        private var observer: (any NSObjectProtocol)?

        init() {
            self.observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.leftForeground = true }
            }
        }

        /// Always called, from the `defer` in `awaitOutcome`, so there is no
        /// `deinit` fallback to reason about.
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            self.observer = nil
        }
    }

    /// Opens the caller's `x-success` URL with the transcript, or `x-cancel`
    /// when nothing was said.
    private static func deliver(_ transcript: String, to callback: CaptureCallback?) {
        guard let callback else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.open(callback.cancelURL, reason: "x-cancel")
            return
        }
        self.open(callback.successURL(transcript: trimmed), reason: "x-success")
    }

    /// Answers the caller of a queued capture link that a later link replaced
    /// before the scene became active.
    ///
    /// Reported to the caller only. The user did not lose anything — the
    /// command they issued last is the one that runs — so there is nothing to
    /// alert them about; the app that is blocked waiting for a return is the
    /// only party that needs to hear.
    static func reportSuperseded(to callback: CaptureCallback) {
        self.open(callback.errorURL(.superseded), reason: "x-error")
    }

    /// Reports a refusal to the caller and to the user. The caller only learns
    /// of it if it passed an `x-error`; the user always gets the alert, because
    /// a link that silently does nothing is the failure this vocabulary keeps
    /// running into.
    static func report(
        _ failure: CaptureLinkFailure,
        to callback: CaptureCallback?,
        notifyUser: Bool = true
    ) {
        SpeakLogger.transcription.warning(
            "Capture link refused: \(failure.rawValue, privacy: .public)"
        )
        if notifyUser {
            TranscriptionRecordingService.shared.reportCaptureFailure(failure)
        }
        self.open(callback?.errorURL(failure), reason: "x-error")
    }

    /// The sanctioned app-to-app return: a plain URL open of a callback that
    /// `CaptureCallback.validated` already accepted. Nothing else in this file
    /// opens a URL, so every caller-supplied destination passes that check.
    static func open(_ url: URL?, reason: String) {
        guard let url else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                SpeakLogger.transcription.warning(
                    "Capture \(reason, privacy: .public) callback could not be opened"
                )
            }
        }
    }
}
#endif
