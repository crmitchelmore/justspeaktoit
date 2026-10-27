#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation

/// The same owned final MP3 as file synthesis, plus this response's playback
/// disposition. The endpoint does not supply a cost. PCM acceptance is not
/// proof that the device has played or finished playing the audio.
public struct OpenRouterProgressiveSpeechResult: Sendable {
    /// Headerless signed little-endian PCM16, mono, at this sample rate.
    public static let sampleRate = 24_000
    public static let channelCount = 1
    public static let bytesPerSample = 2

    public let speech: OpenRouterSpeechResult
    /// At least one chunk was acknowledged by the generation-owned consumer.
    public let pcmProduced: Bool
    /// Native setup was unavailable before acceptance; play this same final
    /// response file once. Never issue a second synthesis request to fall back.
    public let completedFileRequired: Bool
}

#endif
