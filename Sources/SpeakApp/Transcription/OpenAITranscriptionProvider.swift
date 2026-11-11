import Foundation
import SpeakCore

/// Native duration probing stays on Apple; request and response semantics are
/// shared with the Windows app through SpeakCore.
struct OpenAITranscriptionProvider: TranscriptionProvider {
    private let client: OpenAIBatchClient

    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        validationServiceName: String = "OpenAI"
    ) {
        client = OpenAIBatchClient(
            session: session,
            baseURL: baseURL,
            validationServiceName: validationServiceName,
            durationResolver: { url in
                await resolvedTranscriptionDuration(reported: nil, lastSegmentEnd: nil, audioURL: url)
            }
        )
    }

    func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        try await client.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await client.validateAPIKey(key)
    }

    func requiresAPIKey(for model: String) -> Bool { client.requiresAPIKey(for: model) }
    func supportedModels() -> [ModelCatalog.Option] { client.supportedModels() }
}
