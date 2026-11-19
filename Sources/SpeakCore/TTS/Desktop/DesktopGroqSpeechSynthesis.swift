import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopGroqSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let segments: [String]
        do { segments = try GroqTTSAPI.synthesisSegments(source.text) } catch let error as GroqTTSAPIError {
            throw DesktopGroqSpeechError(error)
        }
        let selection = GroqTTSRequest(voiceID: voice.id)
        let flow = DesktopSegmentedWAVSynthesis(
            session: session, sampleRate: 24_000,
            request: { try GroqTTSAPI.synthesisRequest(input: $0, apiKey: $1, request: selection) },
            serviceError: { DesktopGroqSpeechError(GroqTTSAPI.error(from: $0, statusCode: $1)) }
        )
        return try await flow.synthesize(
            segments, voice: voice, missingCredential: DesktopGroqSpeechError.missingCredential,
            credential: credential)
    }
}

public enum DesktopGroqSpeechError: LocalizedError, Equatable {
    case emptyText, missingCredential, invalidResponse, unauthorized, modelTermsRequired, accessBlocked, rateLimited
    case excessiveFanOut(Int), service(Int)

    init(_ error: GroqTTSAPIError) {
        switch error {
        case .emptyText: self = .emptyText
        case .invalidResponse: self = .invalidResponse
        case .excessiveFanOut(let count): self = .excessiveFanOut(count)
        case .unauthorized: self = .unauthorized
        case .modelTermsRequired: self = .modelTermsRequired
        case .accessBlocked: self = .accessBlocked
        case .rateLimited: self = .rateLimited
        case .httpError(let status, _): self = .service(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "Groq needs text in every request. Provide text or shorten long whitespace runs."
        case .missingCredential: "Save the shared Groq API key to use Groq Orpheus Voice output."
        case .invalidResponse: "Groq returned an invalid speech response. No audio was published."
        case .unauthorized: "Groq rejected the saved key. Check the key in Settings."
        case .modelTermsRequired:
            "This Groq model requires organisation approval. Accept its terms at \(GroqTTSAPI.modelTermsURL)."
        case .accessBlocked:
            "Groq blocked this model or reached the account spend limit. Check organisation access and billing."
        case .rateLimited: "Groq speech quota or rate limit reached. Try again later."
        case .excessiveFanOut(let count):
            GroqTTSAPI.excessiveFanOutMessage(segmentCount: count) ?? "Groq request limit exceeded."
        case .service(let status): "Groq speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
