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

        guard await self.start(
            service,
            destinationOverride: link.destination,
            modelOverride: link.modelIdentifier,
            languageOverride: link.languageIdentifier
        ) else {
            self.report(.recordingFailed, to: link.callback)
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
            )

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
            )
        }
    }

    private static func start(
        _ service: TranscriptionRecordingService,
        destinationOverride: HardwareTriggerDestination?,
        modelOverride: String? = nil,
        languageOverride: String? = nil
    ) async -> Bool {
        // The in-app recorder owns the microphone through its own coordinator,
        // which the headless service knows nothing about. Starting here anyway
        // would run two sessions against one input. The App Intents refuse for
        // the same reason (TranscriptionIntents.swift, ToggleRecordingError).
        guard !SharedTranscriptionState.shared.isRecording else {
            SpeakLogger.transcription.info(
                "Capture command ignored: a recording is already running in the app"
            )
            return false
        }
        do {
            try await service.startRecording(
                modelOverride: modelOverride,
                languageOverride: languageOverride
            )
            startedDestination = destinationOverride
            return true
        } catch {
            startedDestination = nil
            SpeakLogger.logError(
                error,
                context: "Capture command start",
                logger: SpeakLogger.transcription
            )
            return false
        }
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
