import Foundation
import SpeakCore

/// The batch transport is shared; native asset duration and OS logging remain
/// in the Apple adapters. Existing call sites and test seams are preserved.
struct MistralTranscriptionProvider: TranscriptionProvider {
    private let client: MistralBatchClient
    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.mistral.ai/v1")!,
        multipartStaging: MultipartUploadStaging = .shared
    ) {
        client = MistralBatchClient(
            session: session, baseURL: baseURL, multipartStaging: multipartStaging.sharedStore,
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

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult { await client.validateAPIKey(key) }
    func requiresAPIKey(for model: String) -> Bool { client.requiresAPIKey(for: model) }
    func supportedModels() -> [ModelCatalog.Option] { client.supportedModels() }

    nonisolated static func makeMultipartUploadBody(
        sourceURL: URL, staging: MultipartUploadStaging, boundary: String, model: String, language: String?
    ) throws -> URL {
        try MistralBatchClient.makeMultipartUploadBody(
            sourceURL: sourceURL, staging: staging.sharedStore, boundary: boundary, model: model, language: language
        )
    }
}
