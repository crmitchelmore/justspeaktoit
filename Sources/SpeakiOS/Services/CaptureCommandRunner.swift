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
    /// Runs a capture verb, mirroring the App Intent semantics.
    ///
    /// - Parameters:
    ///   - action: start, stop or toggle.
    ///   - destinationOverride: used instead of the configured hardware-trigger
    ///     destination for this capture only.
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
            return await start(service)

        case .stop:
            guard isActive else { return false }
            await stop(service, destinationOverride: destinationOverride)
            return true

        case .toggle:
            if isActive {
                await stop(service, destinationOverride: destinationOverride)
                return true
            }
            return await start(service)
        }
    }

    private static func start(_ service: TranscriptionRecordingService) async -> Bool {
        do {
            try await service.startRecording()
            return true
        } catch {
            SpeakLogger.logError(
                error,
                context: "Capture command start",
                logger: SpeakLogger.transcription
            )
            return false
        }
    }

    private static func stop(
        _ service: TranscriptionRecordingService,
        destinationOverride: HardwareTriggerDestination?
    ) async {
        let destination = destinationOverride ?? AppSettings.shared.hardwareTriggerDestination
        await service.stopRecording(destination: destination)
    }
}
#endif
