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
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw DesktopGroqSpeechError.missingCredential }
        let selection = GroqTTSRequest(voiceID: voice.id)
        var pcm = Data()
        for segment in segments {
            try Task.checkCancellation()
            let audio = try await synthesizeSegment(segment, key: key, selection: selection, voice: voice)
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: GroqTTSRequest, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        let request = try GroqTTSAPI.synthesisRequest(input: text, apiKey: key, request: selection)
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count,
                                    usesSSML: false, pricingCharacters: text.count)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(received, sampleRate: 24_000, requireComplete: true)
            } catch {
                throw DesktopSpeechSynthesisError.invalidAudio
            }
            if let ticket { capture?.finish(ticket, outcome: .completed, audioDuration: audio.duration) }
            return audio
        } catch {
            if let ticket { capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        do {
            let response = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120))
            guard (200..<300).contains(response.http.statusCode) else {
                throw DesktopGroqSpeechError(GroqTTSAPI.error(
                    from: response.body, statusCode: response.http.statusCode))
            }
            return response.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? DesktopGroqSpeechError { throw service }
            switch error as? OpenRouterBoundedResponseTransport.Failure {
            case .responseTooLarge: throw DesktopSpeechSynthesisError.audioTooLarge
            case .timedOut: throw DesktopSpeechSynthesisError.timedOut
            case .invalidResponse: throw DesktopSpeechSynthesisError.invalidAudio
            case nil:
                throw (error as? URLError)?.code == .timedOut
                    ? DesktopSpeechSynthesisError.timedOut : DesktopSpeechSynthesisError.transportFailure
            }
        }
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
