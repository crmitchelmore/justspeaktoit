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
            let connection = try AzureSpeechConfiguration.batchConnection(
                credentials: key,
                endpoint: UserDefaults.standard.string(forKey: AzureSpeechConfiguration.endpointDefaultsKey) ?? ""
            )
            if connection.origin.scheme == "http" {
                var request = URLRequest(url: connection.origin.appendingPathComponent("health"), timeoutInterval: 10)
                request.setValue(connection.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
                let redirects = BatchTranscriptionJob.OriginBoundRedirects(origin: connection.origin)
                let (data, response) = try await session.data(for: request, delegate: redirects)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let status = try JSONSerialization.jsonObject(with: data) as? [String: String],
                      status["status"] == "ready", status["scope"] == "batch-transcription-and-tts" else {
                    return .failure(message: "The local proxy is unavailable or does not support batch transcription.")
                }
                return .success(
                    message: "Local proxy connected. Azure sign-in and model access are checked when recording."
                )
            }
            _ = try await AzureSpeechVoiceAPI(session: session).listVoices(credentials: key)
            return .success(
                message: "Azure key and region are valid; transcription access depends on your resource."
            )
        } catch { return .failure(message: error.localizedDescription) }
    }

    func requiresAPIKey(for model: String) -> Bool { true }
    func supportedModels() -> [ModelCatalog.Option] { AzureTranscriptionModels.batchOptions }
}
