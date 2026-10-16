import Foundation

/// A complete lossless result from the executable desktop speech engine.
public struct VoiceGeneratedAudio: Sendable {
    public let wav: Data
    public let duration: TimeInterval

    public init(validating wav: Data) throws {
        guard wav.count <= DeepgramSpeechExport.maximumPCMBytes + 44 else {
            throw DeepgramSpeechError.responseTooLarge
        }

        let audio = try DeepgramSpeechWAV.canonical(wav, sampleRate: 24_000)
        self.wav = audio.wav
        self.duration = audio.duration
    }
}
