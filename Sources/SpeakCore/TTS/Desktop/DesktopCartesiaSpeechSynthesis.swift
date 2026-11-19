import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopCartesiaSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice, options: VoiceSynthesisOptions,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let segments = TTSTextChunker.chunks(source.text)
        guard !segments.isEmpty else { throw DesktopSpeechSynthesisError.invalidAudio }
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw DesktopCartesiaSpeechError.missingCredential }
        let sampleRate = voice.sampleRate(quality: options.quality)
        let selection = CartesiaTTSRequest(
            voiceID: voice.id, outputFormat: .wav(sampleRate: sampleRate),
            languageIdentifier: nil, content: source.text, speed: options.speed)
        return try await DesktopSpeechHTTP.joinedWAV(segments, sampleRate: sampleRate) { segment in
            try await synthesizeSegment(segment, key: key, selection: selection, voice: voice)
        }
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: CartesiaTTSRequest, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        let request = try CartesiaTTSAPI.synthesisRequest(transcript: text, apiKey: key, request: selection)
        return try await DesktopSpeechHTTP.measuredSegment(
            sampleRate: selection.outputFormat.sampleRate,
            begin: { $0.begin(voice: voice, inputCharacters: text.unicodeScalars.count, usesSSML: false) },
            receive: { try await receive(request) }
        )
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        try await DesktopSpeechHTTP.receive(request, session: session) { response in
            guard (200..<300).contains(response.statusCode) else {
                throw DesktopCartesiaSpeechError.service(response.statusCode)
            }
        }
    }
}

public enum DesktopCartesiaSpeechError: LocalizedError, Equatable {
    case missingCredential
    case service(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Save the shared Cartesia API key to use Cartesia Voice output."
        case .service(401), .service(403):
            "Cartesia rejected the saved key or speech access. Check the key and account."
        case .service(402): "The Cartesia account has no speech credit. Check the account's billing."
        case .service(404): "Cartesia does not expose the selected voice on this account. Choose an available voice."
        case .service(429): "Cartesia speech is rate limited. Try again later."
        case .service(let status): "Cartesia speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
