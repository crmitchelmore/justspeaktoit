import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopMistralSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice, inventory: VoiceAccountInventory?,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: MistralTTSAPI.maxInputCharacters)
        guard !segments.isEmpty else { throw DesktopSpeechSynthesisError.invalidAudio }
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw VoiceAccountDiscoveryError.missingCredential(.mistral) }
        guard inventory?.mistral != nil, inventory?.contains(voice) == true,
              inventory?.matchesCredential(key) == true else {
            throw VoiceAccountDiscoveryError.credentialChanged(.mistral)
        }
        let selection = MistralTTSRequest(voiceID: voice.id, responseFormat: .wav)
        let wav = try await DesktopSpeechHTTP.joinedWAV(segments, sampleRate: voice.sampleRate) { segment in
            try await synthesizeSegment(segment, key: key, selection: selection, voice: voice, inventory: inventory)
        }
        try Task.checkCancellation()
        return wav
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: MistralTTSRequest, voice: DesktopSpeechVoice,
        inventory: VoiceAccountInventory?
    ) async throws -> DeepgramSpeechAudio {
        let request = try MistralTTSAPI.synthesisRequest(input: text, apiKey: key, request: selection)
        return try await DesktopSpeechHTTP.measuredSegment(
            sampleRate: voice.sampleRate,
            begin: {
                $0.begin(voice: voice, inputCharacters: text.unicodeScalars.count, usesSSML: false,
                         pricingCharacters: text.count, accountInventory: inventory)
            },
            receive: {
                let received = try await DesktopSpeechHTTP.receive(request, session: session) { response in
                    guard (200..<300).contains(response.statusCode) else {
                        throw DesktopMistralSpeechError.service(response.statusCode)
                    }
                }
                do { return try MistralTTSAPI.decodedAudio(from: received) } catch {
                    throw DesktopSpeechSynthesisError.invalidAudio
                }
            }
        )
    }
}

public enum DesktopMistralSpeechError: LocalizedError, Equatable {
    case service(Int)

    public var errorDescription: String? {
        switch self {
        case .service(401): "Mistral rejected the saved Voice key. Check the key and workspace."
        case .service(403): "Mistral denied speech: check model access, account tier or text moderation."
        case .service(429): "Mistral speech is rate limited. Try again later."
        case .service(let status): "Mistral speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
