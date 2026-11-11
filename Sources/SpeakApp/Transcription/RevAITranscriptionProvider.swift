import AVFoundation
import Foundation
import SpeakCore

/// Keeps native asset duration at the Apple boundary. Requests, polling and
/// response mapping use the same streamed batch client as Windows.
struct RevAITranscriptionProvider: TranscriptionProvider {
    private let client: RevAIBatchClient
    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(session: URLSession = .shared, multipartStaging: MultipartUploadStaging = .shared) {
        client = RevAIBatchClient(
            session: session, multipartStaging: multipartStaging.sharedStore,
            durationResolver: { url in
                let asset = AVURLAsset(url: url)
                return try await asset.load(.duration).seconds
            }
        )
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
