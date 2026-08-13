import Foundation

// MARK: - Watch Recording Lifecycle
//
// Decides what happens to the audio captured so far when a watch recording
// ends — whether the user tapped stop, or watchOS took the app's extra
// runtime away mid-capture.
//
// Pure Foundation, no AVFoundation: the watch app target compiles this file by
// direct source reference (like `WatchCaptureProtocol.swift`) and the rules are
// unit-tested in `SpeakCoreTests` without watch hardware.
//
// The rule that matters: an interrupted or OS-terminated recording is *not*
// thrown away. Anything long enough to be worth transcribing goes into the
// same `recorded → transferring → delivered` queue as a normal capture, so a
// wrist-down recording cut short still reaches iPhone history.

/// Why an in-progress watch recording stopped.
public enum WatchRecordingEndReason: Equatable, Sendable {
    /// The user tapped stop.
    case userStopped
    /// watchOS revoked the runtime keeping the recording alive — the app was
    /// suspended, or the recorder was stopped by the system rather than by us.
    case runtimeInvalidated(reason: String?)
    /// The audio session was interrupted (phone call, Siri, another audio app).
    /// On watchOS a background audio session cannot be reactivated after an
    /// interruption, so this always ends the capture.
    case interrupted
    /// The encoder failed, so the bytes already on disk cannot be trusted.
    case encodingFailed(reason: String?)
}

/// What to do with the audio captured up to the stop.
public enum WatchRecordingDisposition: String, Equatable, Sendable {
    /// Hand the file to the capture queue for transfer to the iPhone.
    case enqueue
    /// Delete the file; it holds nothing worth transcribing.
    case discard
}

/// The decision for one ended recording, plus the message (if any) the watch
/// UI should show to explain it.
public struct WatchRecordingOutcome: Equatable, Sendable {
    public let disposition: WatchRecordingDisposition
    /// User-facing explanation, or `nil` when nothing needs saying.
    public let message: String?

    public init(disposition: WatchRecordingDisposition, message: String?) {
        self.disposition = disposition
        self.message = message
    }
}

/// Maps "the recording ended, for this reason, with this much audio" onto a
/// keep-or-drop decision.
public enum WatchRecordingEndPolicy {
    /// Below this, a capture is an accidental tap (or an OS stop that landed
    /// before any audio was written) rather than speech worth sending.
    public static let minimumUsableDuration: TimeInterval = 0.2

    public static func outcome(
        for reason: WatchRecordingEndReason,
        duration: TimeInterval,
        hasAudioFile: Bool
    ) -> WatchRecordingOutcome {
        // A failed encoder can leave a file behind, but its contents are
        // unusable however long the recording ran.
        if case let .encodingFailed(detail) = reason {
            return WatchRecordingOutcome(
                disposition: .discard,
                message: detail ?? "Recording failed while saving audio."
            )
        }

        let captured = hasAudioFile && duration >= minimumUsableDuration
        return WatchRecordingOutcome(
            disposition: captured ? .enqueue : .discard,
            message: message(for: reason, captured: captured)
        )
    }

    private static func message(for reason: WatchRecordingEndReason, captured: Bool) -> String? {
        switch reason {
        case .userStopped:
            // Both outcomes are exactly what the user asked for: a stop, or an
            // accidental tap that is silently dropped.
            return nil
        case .runtimeInvalidated(let detail):
            if let detail { return detail }
            return captured
                ? "Recording ended on the watch. Sending what was captured."
                : "Recording ended on the watch before any audio was captured."
        case .interrupted:
            return captured
                ? "Recording was interrupted. Sending what was captured."
                : "Recording was interrupted before any audio was captured."
        case .encodingFailed:
            return nil // Handled above.
        }
    }
}
