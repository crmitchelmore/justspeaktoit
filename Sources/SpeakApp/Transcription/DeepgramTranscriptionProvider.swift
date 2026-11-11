import AVFoundation
import Foundation
import SpeakCore

/// Keeps native duration loading on Apple while using the same
/// file-transcription request and result code as the Windows host. Live
/// Deepgram runs on `SharedClientLiveController` with `DeepgramLiveClient`.
struct DeepgramTranscriptionProvider: TranscriptionProvider {
    private let client: DeepgramBatchClient
    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(session: URLSession = .shared) {
        client = DeepgramBatchClient(session: session, durationResolver: { url in
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
