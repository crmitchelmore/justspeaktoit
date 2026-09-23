import AVFoundation
import Foundation
import SpeakCore

/// Keeps native duration loading and live capture on Apple while using the
/// same file-transcription request and result code as the Windows host.
struct DeepgramTranscriptionProvider: TranscriptionProvider {
    private let client: DeepgramBatchClient
    private let session: URLSession
    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(session: URLSession = .shared) {
        self.session = session
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

    /// Creates a live transcriber for streaming audio.
    ///
    /// The transport is the shared `SpeakCore.DeepgramLiveClient` — the same
    /// client iOS streams through — so nova and Flux sessions behave
    /// identically on both platforms and the socket-state synchronisation
    /// lives in one place.
    func createLiveTranscriber(
        apiKey: String,
        model: String = "nova-3",
        language: String? = nil,
        sampleRate: Int = 16000
    ) -> DeepgramLiveClient {
        DeepgramLiveClient(
            apiKey: apiKey,
            model: extractModelName(from: model),
            language: language,
            sampleRate: sampleRate,
            session: session
        )
    }

    // MARK: - Private Methods

    private func extractModelName(from model: String) -> String {
        // Extract the model name after the "/" and remove any "-streaming" suffix
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if name.hasSuffix("-streaming") {
            name = String(name.dropLast("-streaming".count))
        }
        return name
    }

}

// MARK: - Error Types

enum DeepgramError: LocalizedError {
    case invalidURL
    case connectionFailed
    case sendFailed
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct Deepgram WebSocket URL"
        case .connectionFailed:
            return "Failed to establish WebSocket connection to Deepgram"
        case .sendFailed:
            return "Failed to send audio data to Deepgram"
        case .missingAPIKey:
            return "Deepgram API key is missing. Please configure it in Settings."
        }
    }
}
