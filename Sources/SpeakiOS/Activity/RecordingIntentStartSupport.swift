#if os(iOS)
import AppIntents
import Foundation
import SpeakCore

// The start and stop plumbing shared by every recording intent: the keyboard
// hand-off check that runs before any stop, the two-attempt foreground start,
// and the journaled refusal of invalid start parameters.

/// A keyboard-owned dictation shares the microphone with every hardware
/// trigger. Rather than colliding with it — refusing with "already recording",
/// or stopping it into the *hardware* destination and losing the field the
/// keyboard was aiming at — a physical press finishes it into that field
/// (issue #1002).
///
/// Returns `true` when the press was consumed by the keyboard session.
///
/// Every supported stop entry point must run this **before** its own generic
/// stop: `StopTranscriptionRecordingIntent`, the Action Button toggle, the
/// Control Center toggle's off position, and `StopDictationIntent`. Stopping
/// the service directly would finalise a keyboard-owned capture with the
/// *hardware* destination and publish a pickup offer, instead of completing
/// the nonce-scoped handoff into the field the keyboard opened it for.
@available(iOS 18, *)
@MainActor
func finishedKeyboardSessionIfActive() -> Bool {
    switch KeyboardDeliveryPublisher.sessionRouting() {
    case let .finishKeyboardSession(requestID):
        return KeyboardInstantDictationCoordinator.shared.finishKeyboardSession(requestID: requestID)
    case .keyboardSessionStarting:
        // The keyboard has asked for a recording that has not begun. Racing
        // its start-up would either double-start or silently drop it.
        return true
    case .proceed:
        return false
    }
}

/// Starts recording with foreground recovery if the required Live Activity is unavailable.
///
/// `LiveActivityIntent` permits activity creation without opening the app when
/// requested within its awaited `perform()` execution. `AudioRecordingIntent`
/// requires that activity throughout microphone capture. Keep this call awaited
/// so the service can reuse a primed activity or request one before starting audio.
///
/// The grant does not guarantee success in every device state. If the service
/// reports `liveActivityUnavailable`, retain the narrow foreground-continuation
/// retry: the app briefly comes to the front, where starting a Live Activity is
/// permitted, and recording proceeds. Other failures propagate without starting
/// audio through this fallback.
///
/// `entry` is the timestamp taken at `perform()` entry. It is passed through
/// unchanged — including into the foreground retry — so the measured startup
/// covers the intent hop rather than restarting the clock partway down the
/// path (issue #972).
@available(iOS 18, *)
func startRecordingContinuingInForegroundIfNeeded(
    from intent: some ForegroundContinuableIntent,
    trigger: CaptureTrigger,
    parameters: CaptureRunParameters = .none,
    entry: StartupEntry,
    endPointing: CaptureEndPointingRequest? = nil
) async throws {
    let service = await TranscriptionRecordingService.shared
    try await startRecordingWithForegroundRecovery(
        service: service,
        start: { request in
            try await service.startRecording(
                trigger: trigger,
                parameters: parameters,
                endPointing: endPointing,
                destination: nil,
                entry: entry,
                configurationRequest: request
            )
        },
        continueInForeground: { continuation in
            try await intent.requestToContinueInForeground(continuation: continuation)
        }
    )
}

/// The same two-attempt owner, with private operations injectable for local lifecycle tests.
/// A foreground-framework error is not evidence that the user declined permission.
@available(iOS 18, *)
@MainActor
func startRecordingWithForegroundRecovery(
    service: TranscriptionRecordingService,
    start: @escaping @MainActor (CaptureConfigurationRequest) async throws -> Void,
    continueInForeground: (@escaping @MainActor () async throws -> Void) async throws -> Void
) async throws {
    let request = CaptureConfigurationRequest()
    @MainActor func attempt() async throws {
        // Configuration remains frozen across recovery; admission belongs to each attempt.
        request.admittedRunID = nil
        request.serviceStartReturnedNormally = false
        try await start(request)
        request.serviceStartReturnedNormally = true
    }
    do {
        do {
            try await attempt()
        } catch iOSTranscriptionError.liveActivityUnavailable {
            try await continueInForeground { try await attempt() }
        }
    } catch {
        service.recordTerminalStartupFailure(error, request: request)
        throw error
    }
}

/// Resolves a start intent's parameters, journaling a refusal under its own
/// diagnostic code. The refusal happens before the foreground helper, so
/// without this the health screen would keep reporting an older run (#996).
@available(iOS 18, *)
func journalingRefusedStartParameters(
    service: TranscriptionRecordingService,
    _ resolve: () throws -> CaptureRunParameters
) async throws -> CaptureRunParameters {
    do {
        return try resolve()
    } catch let failure as CaptureParameterFailure {
        await service.recordRefusedStartParameters(failure)
        throw failure
    }
}
#endif
