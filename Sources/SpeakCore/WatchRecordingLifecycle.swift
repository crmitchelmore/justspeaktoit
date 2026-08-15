import Foundation

// MARK: - Watch Recording Lifecycle
//
// Persists enough state to recover a recording after process termination and
// decides what happens to the audio captured so far when recording ends.
//
// Pure Foundation, no AVFoundation: the watch app target compiles this file by
// direct source reference (like `WatchCaptureProtocol.swift`) and the rules are
// unit-tested in `SpeakCoreTests` without watch hardware.
//
// The rule that matters: an interrupted or OS-terminated recording is *not*
// thrown away. Anything long enough to be worth transcribing goes into the
// same `recorded → transferring → delivered` queue as a normal capture, so a
// wrist-down recording cut short still reaches iPhone history.

/// Durable identity for a recording that has started but has not yet reached
/// the transfer queue.
///
/// Identity only, deliberately: an absolute file path does not survive an app
/// update or a restore, because the container directory is different in the new
/// installation. A marker written before the update would then point at a dead
/// path, the audio would look unplayable, and a recoverable recording would be
/// discarded while its file stayed behind forever. The path is derived from the
/// id instead — see `fileURL(in:)`.
public struct WatchActiveCapture: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date

    public init(id: UUID, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    /// Markers written by earlier versions also hold a `fileURL`. Naming the
    /// keys keeps that stale value out of the decoded capture.
    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
    }

    /// Where the audio for this capture lives inside `directory`.
    public func fileURL(in directory: URL) -> URL {
        Self.fileURL(for: id, in: directory)
    }

    /// The one place that builds a capture path, so the recorder and recovery
    /// can never disagree about it.
    public static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("m4a")
    }
}

/// File-backed active-capture marker. A new instance reading the same URL
/// models app relaunch, so recovery behaviour can be tested without watchOS.
public struct WatchActiveCaptureRegistry: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func persist(_ capture: WatchActiveCapture) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(capture).write(to: fileURL, options: .atomic)
    }

    public func load() -> WatchActiveCapture? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WatchActiveCapture.self, from: data)
    }

    public func clear(matching id: UUID) throws {
        guard let capture = load(), capture.id == id else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Runs the durable queue write first and consumes the marker only when it
    /// succeeds. A failed write deliberately leaves recovery state intact.
    @discardableResult
    public func clearAfterSuccessfulEnqueue(
        matching id: UUID,
        enqueue: () -> Bool
    ) throws -> Bool {
        guard enqueue() else { return false }
        try clear(matching: id)
        return true
    }
}

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
    /// The encoder reported a failure. The prefix already written may still be
    /// playable, so finalisation validates the asset before discarding it.
    case encodingFailed(reason: String?)
}

/// Result of inspecting the audio asset after the recorder has stopped.
public struct WatchAudioInspection: Equatable, Sendable {
    public let isPlayable: Bool
    public let duration: TimeInterval

    public init(isPlayable: Bool, duration: TimeInterval) {
        self.isPlayable = isPlayable
        self.duration = duration
    }

    public static let unplayable = WatchAudioInspection(isPlayable: false, duration: 0)
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

/// One stopped capture after combining the recorder's live duration with the
/// duration recovered from the finished asset.
public struct WatchRecordingFinalisation: Equatable, Sendable {
    public let capture: WatchActiveCapture
    public let duration: TimeInterval
    public let outcome: WatchRecordingOutcome

    public init(capture: WatchActiveCapture, duration: TimeInterval, outcome: WatchRecordingOutcome) {
        self.capture = capture
        self.duration = duration
        self.outcome = outcome
    }
}

/// Production finalisation boundary shared by normal stops, runtime loss,
/// interruptions, encoder errors and relaunch recovery.
public enum WatchRecordingFinaliser {
    public static func finalise(
        capture: WatchActiveCapture,
        reason: WatchRecordingEndReason,
        recorderDuration: TimeInterval,
        inspection: WatchAudioInspection
    ) -> WatchRecordingFinalisation {
        // `AVAudioRecorder.currentTime` becomes zero after a system-driven
        // stop. Prefer the finished asset's duration whenever it is valid.
        let inspectedDuration = inspection.duration.isFinite ? max(0, inspection.duration) : 0
        let liveDuration = recorderDuration.isFinite ? max(0, recorderDuration) : 0
        let duration = max(inspectedDuration, liveDuration)
        let outcome = WatchRecordingEndPolicy.outcome(
            for: reason,
            duration: duration,
            hasPlayableAudio: inspection.isPlayable
        )
        return WatchRecordingFinalisation(capture: capture, duration: duration, outcome: outcome)
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
        hasPlayableAudio: Bool
    ) -> WatchRecordingOutcome {
        let captured = hasPlayableAudio && duration >= minimumUsableDuration
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
        case .encodingFailed(let detail):
            if captured {
                return detail.map { "\($0) Sending what was captured." }
                    ?? "Recording ended while saving. Sending what was captured."
            }
            return detail ?? "Recording failed while saving audio."
        }
    }
}
