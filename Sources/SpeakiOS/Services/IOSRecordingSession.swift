#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Owned lifecycle boundary, injectable without a microphone or provider connection.
/// Every member the recording owners rely on is here, so a test double stands
/// in for the whole session and the owners never route on the concrete type.
@MainActor
protocol IOSRecordingSession: AnyObject {
    var isBatch: Bool { get }
    var stopCompletionTimeout: TimeInterval { get }
    var resolution: IOSTranscriptionSession.Resolution { get }
    var partialText: String { get }
    var confidence: Double? { get }
    var onPartialResult: ((String, Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onFirstInputBuffer: (() -> Void)? { get set }
    var onStartupObservation: ((StartupObservation) -> Void)? { get set }
    var inputLevelSample: CaptureInputLevelSample { get }
    func resetInputLevel()
    /// The safety recording this capture is writing, or `nil` when it has none.
    var safetyRecordingID: UUID? { get }
    /// Drops a non-retained capture's temporary recording after delivery.
    @discardableResult
    func discardTemporaryRecording() -> Bool
    func start() async throws
    func start(preRollBuffers: [AVAudioPCMBuffer], analyzerFallbackAllowed: Bool) async throws
    func stop() async throws -> TranscriptionResult
    func cancel()
    /// Cancellation stops capture immediately; this waits for whatever the
    /// provider drains afterwards, so an owner can hold its claim until the
    /// microphone is really free (#943).
    func awaitCancellationSettled() async
    /// Publishes a nonfatal capture or writer loss for this run (#950).
    var onRecordingWarning: ((String) -> Void)? { get set }
    /// A summary of this run's losses, once it has finished.
    var recordingLossSummary: String? { get }
}
#endif
