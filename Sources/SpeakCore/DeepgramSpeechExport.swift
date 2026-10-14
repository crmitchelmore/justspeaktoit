import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Synthesizes lossless audio without playback. Only complete, validated segments
/// are joined; callers publish the result atomically after checking cancellation.
public struct DeepgramSpeechExport: Sendable {
    public static let maximumPCMBytes = 64 * 1_024 * 1_024
    private let synthesizer: DeepgramSpeechSynthesizer

    public init(session: URLSession = .shared) {
        synthesizer = DeepgramSpeechSynthesizer(session: session)
    }

    init(synthesizer: DeepgramSpeechSynthesizer) { self.synthesizer = synthesizer }

    public func synthesize(
        _ snapshot: VoiceOutputSourceSnapshot,
        voice: DeepgramSpeechCatalog.Voice,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try Task.checkCancellation()
        let key = try DeepgramVoiceOutput.validatedCredential(try await credential())
        var pcm = Data()
        for text in SpeechTextSegmenter.segments(snapshot.text) {
            try Task.checkCancellation()
            let request = try DeepgramSpeechRequest(text: text, voice: voice)
            guard let utterance = try synthesizer.utterance(for: request) else { continue }
            let audio = try await synthesizer.synthesize(utterance, apiKey: key)
            try Task.checkCancellation()
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= Self.maximumPCMBytes - pcm.count else {
                throw DeepgramSpeechError.responseTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000) else {
            throw DeepgramSpeechError.emptyAudio
        }
        return wav
    }
}
