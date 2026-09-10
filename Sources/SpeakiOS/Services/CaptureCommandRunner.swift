#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// The one place that turns a capture verb into calls on
/// `TranscriptionRecordingService`.
///
/// Every non-intent entry point routes through here — the Home Screen quick
/// action and capture deep links today — so they cannot drift apart. Before
/// this existed the quick action had its own copy of the logic that checked
/// `isRunning` instead of `isActive` (so a press during start-up silently did
/// nothing instead of cancelling) and stopped with no destination, which
/// overwrote the clipboard even for people who had chosen "Save to History
/// Only".
///
/// The App Intents (`StartTranscriptionRecordingIntent` and friends) keep their
/// own `perform` bodies because they also own the intent-specific behaviour:
/// dialogs, authentication policy and the foreground continuation.
@MainActor
public enum CaptureCommandRunner {
    /// A destination override belonging to the capture this runner started.
    ///
    /// Held here rather than applied at stop time by whoever asks, so that an
    /// arbitrary app opening `justspeaktoit://stop?destination=clipboard`
    /// cannot redirect a recording it did not start — which would be a way to
    /// pull someone's dictation onto the pasteboard. The override is only ever
    /// honoured for a capture the same vocabulary began.
    private static var startedDestination: HardwareTriggerDestination?

    /// Runs a parsed capture link: the verb plus its per-capture overrides.
    ///
    /// `dictate` is handled here rather than in `perform(_:destinationOverride:)`
    /// because it is not a single call on the recorder — it starts a capture,
    /// waits for it to end, and hands the transcript back to the caller.
    ///
    /// - Returns: whether a capture was actually started or stopped.
    @discardableResult
    public static func perform(_ link: CaptureDeepLink) async -> Bool {
        if let failure = link.failure {
            self.report(failure, to: link.callback)
            return false
        }
        guard link.action == .dictate else {
            return await self.perform(
                link.action,
                destinationOverride: link.destination,
                modelOverride: link.modelIdentifier,
                languageOverride: link.languageIdentifier
            )
        }
        return await self.dictate(link)
    }

    // MARK: - dictate

    /// One-shot capture that returns its transcript to the caller.
    ///
    /// The refusal rules run before anything opens a microphone: locked device,
    /// app not foreground, or a capture already in flight. That last one is the
    /// existing single-flight rule (issue #943) — a `dictate` arriving mid
    /// recording is refused, never allowed to start a second session.
    private static func dictate(_ link: CaptureDeepLink) async -> Bool {
        let service = TranscriptionRecordingService.shared
        if let refusal = CaptureLinkPolicy.refusal(
            isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            isAppActive: UIApplication.shared.applicationState == .active,
            isCaptureBusy: service.isActive || SharedTranscriptionState.shared.isRecording
        ) {
            self.report(refusal, to: link.callback)
            return false
        }

        let outcome = await self.start(
            service,
            destinationOverride: link.destination,
            modelOverride: link.modelIdentifier,
            languageOverride: link.languageIdentifier
        )
        switch outcome {
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
        case .failed(let surfaced):
            // `notifyUser: !surfaced`: when the start already published the
            // real reason it failed, a generic `recordingFailed` on top of it
            // would be a second alert for one failure — and the vaguer of the
            // two. The caller still gets its `x-error` either way.
            self.report(.recordingFailed, to: link.callback, notifyUser: !surfaced)
            return false
        }

        let transcript = await self.awaitTranscript(service, maxDuration: link.dictateDuration)
        self.deliver(transcript, to: link.callback)
        return true
    }

    /// Waits for the dictation to end, then produces its text.
    ///
    /// Ends either because the deadline passed — this stops the capture itself
    /// and takes the result straight from the recorder — or because something
    /// else stopped it (the Live Activity, the Action Button, a later
    /// `justspeaktoit://stop`), in which case the text that session published is
    /// the answer. Polling rather than observing keeps this to one owner of the
    /// stop, so a dictation can never be stopped twice.
    private static func awaitTranscript(
        _ service: TranscriptionRecordingService,
        maxDuration: TimeInterval
    ) async -> String {
        let deadline = Date().addingTimeInterval(maxDuration)
        while service.isActive, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard service.isActive else {
            return SharedTranscriptionState.shared.lastCompletedTranscript ?? ""
        }
        return await self.stop(service)
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

    /// Reports a refusal to the caller and to the user. The caller only learns
    /// of it if it passed an `x-error`; the user always gets the alert, because
    /// a link that silently does nothing is the failure this vocabulary keeps
    /// running into.
    private static func report(
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
    private static func open(_ url: URL?, reason: String) {
        guard let url else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                SpeakLogger.transcription.warning(
                    "Capture \(reason, privacy: .public) callback could not be opened"
                )
            }
        }
    }

    /// Runs a capture verb, mirroring the App Intent semantics.
    ///
    /// - Parameters:
    ///   - action: start, stop or toggle.
    ///   - destinationOverride: replaces the configured hardware-trigger
    ///     destination for a capture *this call starts*. It is remembered until
    ///     that capture is stopped through this runner, and ignored on a stop of
    ///     a capture started anywhere else. A capture started here but stopped
    ///     from another surface (the Action Button, the Live Activity) uses the
    ///     configured destination, because those paths own their own stop.
    ///   - modelOverride: a validated `ModelCatalog` transcription identifier
    ///     for a capture this call starts, from a link's `model=`.
    ///   - languageOverride: a validated `TranscriptionLanguageCatalog`
    ///     identifier for a capture this call starts, from a link's `lang=`.
    /// - Returns: whether anything was actually started or stopped, so callers
    ///   can report an accurate result.
    @discardableResult
    public static func perform(
        _ action: CaptureDeepLinkAction,
        destinationOverride: HardwareTriggerDestination? = nil,
        modelOverride: String? = nil,
        languageOverride: String? = nil
    ) async -> Bool {
        let service = TranscriptionRecordingService.shared
        // `isActive` rather than `isRunning`: a start-up still in flight is an
        // active operation that a stop must cancel, not a free slot (issue #701).
        let isActive = service.isActive

        switch action {
        case .start, .dictate:
            // `dictate` reaches here only through `perform(_: CaptureDeepLink)`
            // having already handled its wait and callback; on its own it is a
            // start.
            guard !isActive else { return false }
            return await start(
                service,
                destinationOverride: destinationOverride,
                modelOverride: modelOverride,
                languageOverride: languageOverride
            ).didStart

        case .stop:
            guard isActive else { return false }
            _ = await stop(service)
            return true

        case .toggle:
            if isActive {
                _ = await stop(service)
                return true
            }
            return await start(
                service,
                destinationOverride: destinationOverride,
                modelOverride: modelOverride,
                languageOverride: languageOverride
            ).didStart
        }
    }

    /// The result of a start attempt.
    ///
    /// `failed` carries whether the user has already been told, so a caller
    /// with a failure report of its own does not raise a second alert for one
    /// failure.
    enum StartOutcome: Equatable {
        case started
        /// The start was cancelled — a stop, or a second press while start-up
        /// was still in flight. The user asked for this; it is not a failure
        /// and must not be reported as one.
        case cancelled
        /// Nothing is recording. `surfaced` says whether the user has already
        /// been shown the real reason, so nothing downstream stacks a vaguer
        /// alert on top of it.
        case failed(surfaced: Bool)

        var didStart: Bool { self == .started }
    }

    private static func start(
        _ service: TranscriptionRecordingService,
        destinationOverride: HardwareTriggerDestination?,
        modelOverride: String? = nil,
        languageOverride: String? = nil
    ) async -> StartOutcome {
        // The in-app recorder owns the microphone through its own coordinator,
        // which the headless service knows nothing about. Starting here anyway
        // would run two sessions against one input. The App Intents refuse for
        // the same reason (TranscriptionIntents.swift, ToggleRecordingError).
        guard !SharedTranscriptionState.shared.isRecording else {
            SpeakLogger.transcription.info(
                "Capture command ignored: a recording is already running in the app"
            )
            return .failed(surfaced: false)
        }
        do {
            try await service.startRecording(
                modelOverride: modelOverride,
                languageOverride: languageOverride
            )
            startedDestination = destinationOverride
            return .started
        } catch {
            startedDestination = nil
            switch surfaceStartFailure(error, service: service) {
            case .logOnly(.cancelled):
                return .cancelled
            case .logOnly:
                return .failed(surfaced: false)
            case .surface:
                return .failed(surfaced: true)
            }
        }
    }

    /// Makes a terminal start failure visible.
    ///
    /// Without this a Home Screen quick action whose start throws produced a
    /// log line and nothing else: the press looked like it worked, and no
    /// recording ever began (issue #944). The classification is
    /// `CaptureStartFailurePolicy`'s, so what counts as terminal is decided by
    /// a pure unit rather than by this file, and the two silent cases —
    /// cancellation and a superseded run — are read from the recorder's
    /// existing run-identity guard (which turns a retired start into a
    /// `CancellationError`) rather than from a second guard added here.
    ///
    /// - Parameter publish: the sink for a terminal failure; defaults to the
    ///   service's existing published error, which is the same alert path a
    ///   refused capture link and a failed mid-session recording already use.
    /// - Returns: what the policy decided, so callers can tell "the user has
    ///   been told the real reason" from "this is deliberately silent" —
    ///   a cancelled start in particular must not have a generic failure
    ///   reported over the top of it.
    @discardableResult
    static func surfaceStartFailure(
        _ error: Error,
        laterCaptureInFlight: Bool,
        microphoneOwnedElsewhere: Bool,
        publish: (Error) -> Void
    ) -> CaptureStartFailurePolicy.Disposition {
        SpeakLogger.logError(
            error,
            context: "Capture command start",
            logger: SpeakLogger.transcription
        )
        let disposition = CaptureStartFailurePolicy.disposition(
            errorDescription: error.localizedDescription,
            isCancellation: error is CancellationError,
            laterCaptureInFlight: laterCaptureInFlight,
            microphoneOwnedElsewhere: microphoneOwnedElsewhere
        )
        switch disposition {
        case .logOnly(let reason):
            SpeakLogger.transcription.info(
                "Capture start failure not shown: \(reason.rawValue, privacy: .public)"
            )
        case .surface(let message):
            // The policy's message, not the original error: that is where a
            // blank or padded `localizedDescription` has already been replaced
            // by the fallback or trimmed. The original is in the log above.
            publish(CaptureStartFailurePolicy.PresentedFailure(message: message))
        }
        return disposition
    }

    private static func surfaceStartFailure(
        _ error: Error,
        service: TranscriptionRecordingService
    ) -> CaptureStartFailurePolicy.Disposition {
        self.surfaceStartFailure(
            error,
            // Asked *after* the failure: a capture active now is a newer run
            // that replaced this one, so this failure is stale.
            laterCaptureInFlight: service.isActive,
            microphoneOwnedElsewhere: SharedTranscriptionState.shared.isRecording,
            publish: service.reportCaptureFailure
        )
    }

    /// - Returns: the transcript this stop produced, which `dictate` returns to
    ///   its caller. Every other caller discards it.
    private static func stop(_ service: TranscriptionRecordingService) async -> String {
        let destination = startedDestination ?? AppSettings.shared.hardwareTriggerDestination
        startedDestination = nil
        return await service.stopRecording(destination: destination).text
    }
}
#endif
