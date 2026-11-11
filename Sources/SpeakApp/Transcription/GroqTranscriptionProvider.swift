import Foundation
import SpeakCore

/// The Groq endpoint, catalogue and request contract are shared by all desktops.
struct GroqTranscriptionProvider: TranscriptionProvider {
    private let client: GroqBatchClient
    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(session: URLSession = .shared) {
        client = GroqBatchClient(session: session, durationResolver: { url in
            await resolvedTranscriptionDuration(reported: nil, lastSegmentEnd: nil, audioURL: url)
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
