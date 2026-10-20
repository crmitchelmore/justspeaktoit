import Foundation

/// Captured export bytes plus native-decoded PCM for device-independent retained playback.
public struct VoiceGeneratedAudio: Sendable {
    public let wav: Data
    public let data: Data
    public let format: VoiceAudioFormat
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
        self.data = audio.wav
        self.format = .wav
        self.duration = audio.duration
        self.sampleRate = audio.sampleRate
    }

    /// Compressed results must have survived the same native codec's full decode at the captured rate.
    public init(encoded data: Data, format: VoiceAudioFormat, decodedWAV: Data, sampleRate: Int) throws {
        try format.validateContainer(data)
        let playback = try Self(validating: decodedWAV, sampleRate: sampleRate)
        guard format != .wav || data == playback.wav else { throw VoiceAudioFormatError.invalidContainer }
        self.wav = playback.wav
        self.data = data
        self.format = format
        self.duration = playback.duration
        self.sampleRate = playback.sampleRate
    }
}
