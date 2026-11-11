import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopSpeechmaticsSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let segments = SpeechTextSegmenter.segments(source.text)
        let selection = SpeechmaticsTTSRequest(voiceID: voice.id)
        let flow = DesktopSegmentedWAVSynthesis(
            session: session, sampleRate: selection.outputFormat.sampleRate,
            request: { try SpeechmaticsTTSAPI.synthesisRequest(text: $0, apiKey: $1, request: selection) },
            serviceError: { DesktopSpeechmaticsSpeechError(SpeechmaticsTTSAPI.error(from: $0, statusCode: $1)) }
        )
        return try await flow.synthesize(
            segments, voice: voice, missingCredential: DesktopSpeechmaticsSpeechError.missingCredential,
            credential: credential)
    }
}

public enum DesktopSpeechmaticsSpeechError: LocalizedError, Equatable {
    case emptyText, missingCredential, invalidResponse, unauthorized, quotaExceeded, rateLimited, service(Int)

    init(_ error: SpeechmaticsTTSAPIError) {
        switch error {
        case .emptyText: self = .emptyText
        case .invalidResponse: self = .invalidResponse
        case .unauthorized: self = .unauthorized
        case .quotaExceeded: self = .quotaExceeded
        case .rateLimited: self = .rateLimited
        case .httpError(let status, _): self = .service(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptyText: "There is no text to speak."
        case .missingCredential: "Save the shared Speechmatics API key to use Speechmatics Voice output."
        case .invalidResponse: "Speechmatics returned an invalid speech response. No audio was published."
        case .unauthorized: "Speechmatics rejected the saved key. Check the key in Settings."
        case .quotaExceeded: "Speechmatics speech credit is exhausted. Check the account balance."
        case .rateLimited: "Speechmatics speech quota or rate limit reached. Try again later."
        case .service(let status): "Speechmatics speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
