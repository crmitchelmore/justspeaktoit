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

    /// Which capture the override above belongs to.
    ///
    /// The override alone is not enough: a capture started here can be stopped
    /// from a surface that never consults this runner — the Action Button, the
    /// Live Activity — and that path leaves `startedDestination` set. A later
    /// capture started from somewhere else would then be finalised with the
    /// earlier link's destination if a `justspeaktoit://stop` reached it, which
    /// is the same "an arbitrary caller redirects a recording it did not start"
    /// hole from the other end. Pinning the capture's identity means a stale
    /// override simply does not match and is discarded.
    private static var startedCaptureID: UUID?

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

        if let failure = await self.start(
            service,
            destinationOverride: link.destination,
            modelOverride: link.modelIdentifier,
            languageOverride: link.languageIdentifier
        ) {
            self.report(failure, to: link.callback)
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
    private static func report(_ failure: CaptureLinkFailure, to callback: CaptureCallback?) {
        SpeakLogger.transcription.warning(
            "Capture link refused: \(failure.rawValue, privacy: .public)"
        )
        TranscriptionRecordingService.shared.reportCaptureFailure(failure)
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
            ) == nil

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
            ) == nil
        }
    }

    /// - Returns: `nil` when the capture started, or why it did not.
    ///
    /// The recorder's own refusals are preserved rather than flattened: a
    /// `model=` this device cannot honour comes back as `.modelUnavailable`, not
    /// as the generic `.recordingFailed`, so the caller's `x-error` says which
    /// of its parameters was the problem.
    private static func start(
        _ service: TranscriptionRecordingService,
        destinationOverride: HardwareTriggerDestination?,
        modelOverride: String? = nil,
        languageOverride: String? = nil
    ) async -> CaptureLinkFailure? {
        // The in-app recorder owns the microphone through its own coordinator,
        // which the headless service knows nothing about. Starting here anyway
        // would run two sessions against one input. The App Intents refuse for
        // the same reason (TranscriptionIntents.swift, ToggleRecordingError).
        guard !SharedTranscriptionState.shared.isRecording else {
            SpeakLogger.transcription.info(
                "Capture command ignored: a recording is already running in the app"
            )
            return .alreadyRecording
        }
        do {
            try await service.startRecording(
                modelOverride: modelOverride,
                languageOverride: languageOverride
            )
            startedDestination = destinationOverride
            startedCaptureID = service.currentSessionID
            return nil
        } catch {
            startedDestination = nil
            startedCaptureID = nil
            SpeakLogger.logError(
                error,
                context: "Capture command start",
                logger: SpeakLogger.transcription
            )
            return error as? CaptureLinkFailure ?? .recordingFailed
        }
    }

    /// - Returns: the transcript this stop produced, which `dictate` returns to
    ///   its caller. Every other caller discards it.
    private static func stop(_ service: TranscriptionRecordingService) async -> String {
        // Honoured only for the capture this runner actually started. Anything
        // else — a capture begun elsewhere, or a stale override left behind when
        // a runner-started capture was stopped from another surface — falls back
        // to the configured destination.
        let ownsCapture = startedCaptureID != nil && startedCaptureID == service.currentSessionID
        let destination = (ownsCapture ? startedDestination : nil)
            ?? AppSettings.shared.hardwareTriggerDestination
        startedDestination = nil
        startedCaptureID = nil
        return await service.stopRecording(destination: destination).text
    }
}
#endif
