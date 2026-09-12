import Foundation
import SpeakCore

struct AzureTranscriptionProvider: TranscriptionProvider {
    let metadata = TranscriptionProviderMetadata(
        id: "azure", displayName: "Azure Speech", systemImage: "cloud", tintColor: "blue",
        website: "https://portal.azure.com", apiKeyIdentifier: AzureSpeechConfiguration.credentialIdentifier
    )
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func transcribeFile(at url: URL, apiKey: String, model: String,
                        language: String?) async throws -> TranscriptionResult {
        try await AzureBatchTranscriptionClient(session: session).transcribeFile(
            at: url, credentials: apiKey,
            endpoint: UserDefaults.standard
                .string(forKey: AzureSpeechConfiguration.endpointDefaultsKey) ?? "",
            model: model, language: language
        )
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        do {
            _ = try await AzureSpeechVoiceAPI(session: session).listVoices(credentials: key)
            return .success(
                message: "Azure key and region are valid; transcription access depends on your resource."
            )
        } catch { return .failure(message: error.localizedDescription) }
    }

    func requiresAPIKey(for model: String) -> Bool { true }
    func supportedModels() -> [ModelCatalog.Option] { AzureTranscriptionModels.batchOptions }
}
