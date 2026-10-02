import AVFoundation
import Foundation
import SpeakCore

/// Native duration probing stays on Apple; the Scribe request and response
/// contract is shared with the Windows host.
struct ElevenLabsTranscriptionProvider: TranscriptionProvider {
    private let client: ElevenLabsBatchClient
    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(session: URLSession = .shared) {
        client = ElevenLabsBatchClient(session: session, durationResolver: { url in
            try await AVURLAsset(url: url).load(.duration).seconds
        })
    }

    func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        try await client.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult { await client.validateAPIKey(key) }
    func requiresAPIKey(for model: String) -> Bool { client.requiresAPIKey(for: model) }
    func supportedModels() -> [ModelCatalog.Option] { client.supportedModels() }
}
