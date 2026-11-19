#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import AudioToolbox
import Foundation

/// The actor owns all parser/converter calls. Native callbacks are synchronous;
/// their borrowed bytes are copied before returning and never cross an await.
actor IncrementalMP3Decoder {
    enum Failure: Error {
        /// Only native codec/setup unavailability permits same-response file fallback.
        case unavailable
        case invalidAudio
    }

    static let sampleRate = OpenRouterProgressiveSpeechResult.sampleRate
    static let maximumPCMFrames = 2_400
    static let maximumCompressedBytes = 256 * 1024
    private var validator = MP3FrameBoundaryValidator()
    private let nativeFactory: @Sendable () throws -> IncrementalMP3NativeState
    private var native: IncrementalMP3NativeState?
    private var inputFinished = false
    private var disabled = false
    private var closed = false

    init(
        nativeFactory: @escaping @Sendable () throws -> IncrementalMP3NativeState = {
            try IncrementalMP3NativeState()
        }
    ) {
        self.nativeFactory = nativeFactory
    }

    func append(_ data: Data) throws {
        try Task.checkCancellation()
        guard !closed, !inputFinished else { throw Failure.invalidAudio }
        guard !data.isEmpty else { return }
        try validator.append(data)
        guard !disabled else { return }
        if native == nil { native = try nativeFactory() }
        try native?.append(data)
    }

    func finishInput() throws {
        try Task.checkCancellation()
        guard !closed, !inputFinished else { throw Failure.invalidAudio }
        try validator.finish()
        inputFinished = true
        if !disabled { try native?.finishInput() }
    }

    /// At most 100 ms of mono 24 kHz signed little-endian PCM16 per call.
    func nextPCM() throws -> Data? {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return try native?.nextPCM()
    }

    /// Retain the framing validator when setup is unavailable. A malformed or
    /// truncated response is still refused instead of being replayed as a file.
    func useCompletedFile() {
        native?.close()
        native = nil
        disabled = true
    }

    func close() {
        native?.close()
        native = nil
        closed = true
    }
}
#endif
