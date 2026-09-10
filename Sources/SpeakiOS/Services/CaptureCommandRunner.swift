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
    /// Carries two things a caller needs and cannot recover afterwards: the
    /// specific reason, so a `model=` this device cannot honour reaches the
    /// caller's `x-error` as `.modelUnavailable` rather than a generic
    /// `.recordingFailed`; and whether the user has already been shown that
    /// reason, so nothing stacks a vaguer alert on top of one failure.
    enum StartOutcome: Equatable {
        case started
        /// The start was cancelled — a stop, or a second press while start-up
        /// was still in flight. The user asked for this; it is not a failure
        /// and must not be reported as one.
        case cancelled
        /// Nothing is recording.
        case failed(CaptureLinkFailure, surfaced: Bool)

        var didStart: Bool { self == .started }
    }

    /// Internal rather than private: `dictate` lives in
    /// `CaptureCommandRunner+Dictate.swift`.
    static func start(
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
            // The surface that owns the microphone is on screen showing the
            // recording it is running, so a second alert would only contradict
            // it — the same reasoning as the policy's `ownedByAnotherSurface`.
            return .failed(.alreadyRecording, surfaced: true)
        }
        do {
            // The per-run overrides travel with the capture, so every stop path
            // — the Live Activity button, an interruption, a Siri stop — sees
            // the same destination, language and model this link asked for.
            try await service.startRecording(
                parameters: CaptureRunParameters(
                    destinationID: destinationOverride?.rawValue,
                    languageIdentifier: languageOverride,
                    modelID: modelOverride
                )
            )
            startedDestination = destinationOverride
            return .started
        } catch {
            startedDestination = nil
            // The recorder's own refusals are preserved rather than flattened:
            // a `model=` this device cannot honour throws
            // `CaptureLinkFailure.modelUnavailable`, and that is what the
            // caller's `x-error` should say. `surfaceStartFailure` logs the
            // error and decides, separately, whether the *user* sees it.
            let failure = error as? CaptureLinkFailure ?? .recordingFailed
            switch surfaceStartFailure(error, service: service) {
            case .logOnly(.cancelled):
                return .cancelled
            case .logOnly:
                return .failed(failure, surfaced: false)
            case .surface:
                return .failed(failure, surfaced: true)
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
    /// Internal rather than private: `dictate` owns its own stop.
    static func stop(_ service: TranscriptionRecordingService) async -> String {
        let destination = startedDestination ?? AppSettings.shared.hardwareTriggerDestination
        startedDestination = nil
        return await service.stopRecording(destination: destination).text
    }
}
#endif
