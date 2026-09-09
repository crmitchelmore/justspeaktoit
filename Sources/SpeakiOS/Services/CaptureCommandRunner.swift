#if os(iOS)
import Foundation
import SpeakCore

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
    /// - Returns: whether anything was actually started or stopped, so callers
    ///   can report an accurate result.
    @discardableResult
    public static func perform(
        _ action: CaptureDeepLinkAction,
        destinationOverride: HardwareTriggerDestination? = nil
    ) async -> Bool {
        let service = TranscriptionRecordingService.shared
        // `isActive` rather than `isRunning`: a start-up still in flight is an
        // active operation that a stop must cancel, not a free slot (issue #701).
        let isActive = service.isActive

        switch action {
        case .start:
            guard !isActive else { return false }
            return await start(service, destinationOverride: destinationOverride)

        case .stop:
            guard isActive else { return false }
            await stop(service)
            return true

        case .toggle:
            if isActive {
                await stop(service)
                return true
            }
            return await start(service, destinationOverride: destinationOverride)
        }
    }

    private static func start(
        _ service: TranscriptionRecordingService,
        destinationOverride: HardwareTriggerDestination?
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
            try await service.startRecording()
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

    private static func stop(_ service: TranscriptionRecordingService) async {
        let destination = startedDestination ?? AppSettings.shared.hardwareTriggerDestination
        startedDestination = nil
        await service.stopRecording(destination: destination)
    }
}
#endif
