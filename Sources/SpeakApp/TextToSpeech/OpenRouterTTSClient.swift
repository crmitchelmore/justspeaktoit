import AVFoundation
import Foundation
import SpeakCore

/// Adapts shared OpenRouter speech transport to normal macOS voice output.
actor OpenRouterTTSClient: TextToSpeechClient {
    let provider: TTSProvider = .openrouter
    private let api: OpenRouterAudioClient
    private let validationClient: OpenRouterAPIClient

    init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
        self.api = OpenRouterAudioClient(
            apiKeyProvider: { try? await secureStorage.secret(identifier: TTSProvider.openrouter.apiKeyIdentifier) },
            session: session
        )
        self.validationClient = OpenRouterAPIClient(secureStorage: secureStorage, session: session)
    }

    func synthesize(text: String, voice: String, settings _: TTSSettings) async throws -> TTSResult {
        guard let selection = OpenRouterSpeechSelection(id: voice) else {
            throw TTSError.invalidVoice("Select an OpenRouter speech model and voice again.")
        }
        // Speed support is model-specific. Apply the preference during local playback
        // until discovery metadata can establish support for a speech request parameter.
        let result: OpenRouterSpeechResult
        do {
            result = try await api.synthesize(text: text, model: selection.modelID, voice: selection.voice)
        } catch {
            if error is CancellationError { throw error }
            throw Self.ttsError(for: error)
        }
        do {
            try Task.checkCancellation()
            let duration = try await AVURLAsset(url: result.audioURL).load(.duration)
            try Task.checkCancellation()
            return TTSResult(
                audioURL: result.audioURL, provider: provider, voice: selection.id,
                duration: CMTimeGetSeconds(duration), characterCount: text.count, cost: result.cost
            )
        } catch {
            try? FileManager.default.removeItem(at: result.audioURL)
            if error is CancellationError { throw error }
            throw TTSError.synthesisFailure("OpenRouter returned audio that could not be played.")
        }
    }

    static func ttsError(for error: Error) -> TTSError {
        if let clientError = error as? OpenRouterClientError, case .apiKeyMissing = clientError {
            return .apiKeyMissing(.openrouter)
        }
        guard let audioError = error as? OpenRouterAudioError else {
            return .synthesisFailure("The OpenRouter speech request could not be completed.")
        }
        switch audioError {
        case .httpStatus(401), .httpStatus(403): return .apiKeyMissing(.openrouter)
        case .httpStatus(402): return .synthesisFailure("OpenRouter credits are exhausted. Check your account balance.")
        case .httpStatus(404):
            return .synthesisFailure("This OpenRouter speech model is unavailable. Choose another model.")
        case .httpStatus(429):
            return .synthesisFailure("OpenRouter is rate limiting speech requests. Try again shortly.")
        default: return .synthesisFailure(audioError.localizedDescription)
        }
    }

    // Discovery belongs to the shared browser; it never supplies a copied fallback list.
    func listVoices() async throws -> [TTSVoice] { [] }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await validationClient.validateAPIKey(key)
    }
}

extension VoiceCatalog {
    static func openRouterVoice(_ selection: OpenRouterSpeechSelection) -> TTSVoice {
        TTSVoice(
            id: selection.id,
            name: selection.modelID + (selection.voice.map { " · \($0)" } ?? " · Model default voice"),
            provider: .openrouter, traits: [], previewURL: nil
        )
    }

    /// Preserve a saved dynamic selection even when offline or no longer advertised.
    static func includingSelection(_ id: String, in voices: [TTSVoice]) -> [TTSVoice] {
        guard !voices.contains(where: { $0.id == id }), let selected = voice(forID: id) else { return voices }
        return voices + [selected]
    }
}

/// Owns only generated OpenRouter files; saved exports and historical metadata are independent.
final class OpenRouterSpeechOutput {
    private(set) var audioURL: URL?

    func replace(with result: TTSResult) {
        if let audioURL, audioURL != result.audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = result.provider == .openrouter ? result.audioURL : nil
    }

    deinit {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
    }
}
