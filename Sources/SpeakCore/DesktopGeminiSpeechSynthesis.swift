import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopGeminiSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice, language: String? = nil,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        guard case .gemini(_, let model) = voice else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: GeminiTTSAPI.maxInputCharacters)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DesktopGeminiSpeechError.emptySegment
        }
        try Self.validateLanguage(language)
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw DesktopGeminiSpeechError.missingCredential }
        let selection = GeminiTTSRequest(model: model, voiceID: voice.id, languageIdentifier: language)
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
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: GeminiTTSAPI.defaultSampleRate) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
    }

    static func validateLanguage(_ language: String?) throws {
        let identifier = VoiceOutputLanguageCatalog.normalizedIdentifier(language)
            .replacingOccurrences(of: "-", with: "_").lowercased()
        guard identifier == VoiceOutputLanguageCatalog.automaticIdentifier
            || VoiceOutputLanguageCatalog.options.contains(where: {
                $0.id.replacingOccurrences(of: "-", with: "_").lowercased() == identifier
            }) else { throw DesktopGeminiSpeechError.unsupportedLanguage }
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: GeminiTTSRequest, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        let request = try GeminiTTSAPI.synthesisRequest(input: text, apiKey: key, request: selection)
        var attempt = 0
        while true {
            do {
                return try await performAttempt(request, text: text, voice: voice)
            } catch let error as GeminiTTSAPIError {
                guard GeminiTTSAPI.isRetryable(error), attempt < GeminiTTSAPI.serverFaultRetries else {
                    throw DesktopGeminiSpeechError(error)
                }
                attempt += 1
                try Task.checkCancellation()
            }
        }
    }

    private func performAttempt(
        _ request: URLRequest, text: String, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        try Task.checkCancellation()
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count, usesSSML: false)
        var reportedTokens: Int?
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let result = try GeminiTTSAPI.audio(
                from: received, requestedSampleRate: GeminiTTSAPI.defaultSampleRate,
                reportInputTokens: { reportedTokens = $0 })
            guard result.sampleRate == GeminiTTSAPI.defaultSampleRate, result.channels == 1,
                  let playable = result.playableData else { throw DesktopSpeechSynthesisError.invalidAudio }
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(
                    playable, sampleRate: GeminiTTSAPI.defaultSampleRate, requireComplete: true)
            } catch { throw DesktopSpeechSynthesisError.invalidAudio }
            if let ticket {
                capture?.finish(ticket, outcome: .completed, audioDuration: audio.duration,
                                reportedInputTokens: reportedTokens)
            }
            return audio
        } catch {
            if let ticket {
                capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed,
                                reportedInputTokens: reportedTokens)
            }
            throw error
        }
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        do {
            let response = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120))
            guard (200..<300).contains(response.http.statusCode) else {
                throw GeminiTTSAPI.error(from: response.body, statusCode: response.http.statusCode)
            }
            return response.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? GeminiTTSAPIError { throw service }
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

public enum DesktopGeminiSpeechError: LocalizedError, Equatable {
    case missingCredential, invalidResponse, noAudioReturned, unsupportedLanguage, emptySegment
    case unauthorized, permissionDenied, rateLimited, contentBlocked
    case service(Int)

    init(_ error: GeminiTTSAPIError) {
        switch error {
        case .invalidResponse, .emptyText: self = .invalidResponse
        case .noAudioReturned: self = .noAudioReturned
        case .unauthorized: self = .unauthorized
        case .permissionDenied: self = .permissionDenied
        case .rateLimited: self = .rateLimited
        case .contentBlocked: self = .contentBlocked
        case .httpError(let status, _): self = .service(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Save the shared Google API key to use Gemini Voice output."
        case .unsupportedLanguage:
            "The stored Gemini voice language is unavailable. Choose Automatic or a catalogue language; "
                + "the saved preference is unchanged."
        case .emptySegment:
            "A Gemini request contains only whitespace. Shorten long whitespace runs before generating speech."
        case .invalidResponse: "Gemini returned an invalid speech response. No audio was published."
        case .noAudioReturned: "Gemini returned no audio after the bounded retry. Try again."
        case .unauthorized: "Gemini rejected the saved Google key. Check the key in Settings."
        case .permissionDenied: "The saved Google key cannot access this Gemini speech model."
        case .rateLimited: "Gemini speech quota or rate limit reached. Check the account or try again later."
        case .contentBlocked: "Gemini declined this speech input. Change the text or choose another provider."
        case .service(let status): "Gemini speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
