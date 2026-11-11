import Foundation
import SpeakCore

struct AlibabaTranscriptionProvider: TranscriptionProvider {
    let metadata = TranscriptionProviderMetadata(
        id: "alibaba", displayName: "Alibaba Model Studio", systemImage: "waveform", tintColor: "orange",
        website: "https://bailian.console.aliyun.com"
    )
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        try await AlibabaAppleBatchTranscription.transcribeFile(
            at: url, credentials: apiKey, model: model, language: language, session: session
        )
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        do {
            _ = try AlibabaSpeechConfiguration(credentials: key)
            return .success(
                message: "Configuration checked locally. Key and model access are checked when transcribing."
            )
        } catch { return .failure(message: error.localizedDescription) }
    }

    func requiresAPIKey(for model: String) -> Bool { true }
    func supportedModels() -> [ModelCatalog.Option] { AlibabaSpeechModels.batchOptions }
}
