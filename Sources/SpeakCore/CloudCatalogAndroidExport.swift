import Foundation

/// The cloud catalogue the Android app offers, as JSON, so Android never keeps its own copy of
/// model identifiers, names, wire fields or the cleanup prompt.
///
/// Android implements OpenAI-compatible `/audio/transcriptions` uploads for OpenAI and Groq and
/// OpenRouter chat for cleanup. It therefore offers every current batch model of those
/// transcription providers that OpenAI's client sends directly (Groq reuses that client), except
/// models with an announced retirement: Android has no saved-selection migration, so it never
/// starts offering a model that is about to shut down.
///
/// `CloudCatalogAndroidExportTests` fails when the committed asset is stale; regenerate it with
/// `UPDATE_CLOUD_CATALOG_ANDROID=1 swift test --filter CloudCatalogAndroidExportTests`.
public enum CloudCatalogAndroidExport {
    /// Providers whose OpenAI-compatible transcription endpoint Android implements, in settings order.
    static let transcriptionProviderIDs = ["openai", "groq"]

    /// The batch models Android offers, in catalogue order; the first is Android's default.
    static var transcriptionModels: [ModelCatalog.Option] {
        ModelCatalog.batchTranscription.filter { option in
            let provider = providerID(of: option.id)
            guard transcriptionProviderIDs.contains(provider) else { return false }
            if provider == "openai", !OpenAITranscriptionModels.directBatchModelIDs.contains(option.id) {
                return false
            }
            return ModelRetirements.retirement(for: option.id) == nil
        }
    }

    public static func json() throws -> Data {
        struct Provider: Encodable {
            let id, credentialId: String
        }
        struct Model: Encodable {
            let catalogId, displayName, provider, apiName, languageField: String
        }
        struct Cleanup: Encodable {
            let provider, model, systemPrompt: String
        }
        struct Document: Encodable {
            let version: Int
            let providers: [Provider]
            let transcriptionModels: [Model]
            let cleanup: Cleanup
        }
        let providerIDs = transcriptionProviderIDs + [OpenRouterService.providerID]
        let document = Document(
            version: 1,
            providers: providerIDs.map {
                Provider(id: $0, credentialId: ProviderCredentialCatalogue.apiKeyIdentifier(for: $0))
            },
            transcriptionModels: transcriptionModels.map { option in
                // The OpenAI client (also used for Groq) sends the last path component as the model.
                let apiName = String(option.id.split(separator: "/").last ?? Substring(option.id))
                return Model(
                    catalogId: option.id, displayName: option.displayName, provider: providerID(of: option.id),
                    apiName: apiName,
                    languageField: OpenAITranscriptionModels.batchLanguageFieldName(for: apiName)
                )
            },
            cleanup: Cleanup(
                provider: OpenRouterService.providerID,
                model: ModelCatalog.defaultPostProcessingModel,
                systemPrompt: TranscriptCleanupPolicy.systemPrompt()
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    private static func providerID(of catalogID: String) -> String {
        String(catalogID.prefix { $0 != "/" })
    }
}
