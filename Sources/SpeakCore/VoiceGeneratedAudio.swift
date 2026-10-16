import Foundation

/// A complete lossless result from the executable desktop speech engine.
public struct VoiceGeneratedAudio: Sendable {
    public let wav: Data
    public let duration: TimeInterval
    public let sampleRate: Int

    public init(validating wav: Data, sampleRate: Int = 24_000) throws {
        guard wav.count <= DeepgramSpeechExport.maximumPCMBytes + 44 else {
            throw DeepgramSpeechError.responseTooLarge
        }

        guard VoiceSynthesisQuality.allCases.contains(where: { $0.sampleRate == sampleRate }) else {
            throw DeepgramSpeechError.unsupportedAudioFormat
        }
        let audio = try DeepgramSpeechWAV.canonical(wav, sampleRate: sampleRate)
        self.wav = audio.wav
        self.duration = audio.duration
        self.sampleRate = audio.sampleRate
    }
}
