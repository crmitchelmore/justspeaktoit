import Foundation

/// The cloud catalogue the Android app offers, as JSON, so Android never keeps its own copy of
/// model identifiers, names, wire fields or the cleanup prompt.
///
/// Android implements OpenAI-compatible `/audio/transcriptions` uploads for OpenAI and Groq, and
/// OpenAI-compatible chat for cleanup through every native text provider and OpenRouter. It
/// therefore offers every current batch model of those transcription providers that OpenAI's
/// client sends directly (Groq reuses that client), except models with an announced retirement:
/// Android has no saved-selection migration, so it never starts offering a model that is about to
/// shut down.
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

    /// Cleanup models Android offers, in catalogue order: native provider routes, then OpenRouter
    /// slugs. On-device and Apple cleanup engines are Mac-only.
    static var cleanupModels: [ModelCatalog.Option] { ModelCatalog.cloudPostProcessing }

    private struct Provider: Encodable {
        let id, credentialId: String
        /// Native text providers only: the cleanup endpoint, which Android's transport must match.
        let chatCompletionsURL: String?
    }

    private struct Model: Encodable {
        let catalogId, displayName, provider, apiName, languageField: String
    }

    private struct Cleanup: Encodable {
        let provider, model, systemPrompt: String
    }

    private struct CleanupModel: Encodable {
        let selectionId, displayName, provider, apiName: String
    }

    private struct Document: Encodable {
        let version: Int
        let providers: [Provider]
        let transcriptionModels: [Model]
        let cleanup: Cleanup
        let cleanupModels: [CleanupModel]
    }

    public static func json() throws -> Data {
        let document = Document(
            version: 1,
            providers: providers,
            transcriptionModels: transcriptionModels.map(exported),
            cleanup: Cleanup(
                provider: OpenRouterService.providerID,
                model: ModelCatalog.defaultPostProcessingModel,
                systemPrompt: TranscriptCleanupPolicy.systemPrompt()
            ),
            cleanupModels: cleanupModels.map(exportedCleanup)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    /// Transcription providers, then OpenRouter, then the remaining native text providers.
    private static var providers: [Provider] {
        var ids = transcriptionProviderIDs + [OpenRouterService.providerID]
        ids += NativeTextModels.providers.map(\.id).filter { !ids.contains($0) }
        return ids.map { id in
            Provider(
                id: id, credentialId: ProviderCredentialCatalogue.apiKeyIdentifier(for: id),
                chatCompletionsURL: NativeTextModels.providers.first { $0.id == id }?
                    .chatCompletionsURL.absoluteString
            )
        }
    }

    private static func exported(_ option: ModelCatalog.Option) -> Model {
        // The OpenAI client (also used for Groq) sends the last path component as the model.
        let apiName = String(option.id.split(separator: "/").last ?? Substring(option.id))
        return Model(
            catalogId: option.id, displayName: option.displayName, provider: providerID(of: option.id),
            apiName: apiName,
            languageField: OpenAITranscriptionModels.batchLanguageFieldName(for: apiName)
        )
    }

    private static func exportedCleanup(_ option: ModelCatalog.Option) -> CleanupModel {
        if let route = NativeTextModels.route(for: option.id) {
            return CleanupModel(
                selectionId: option.id, displayName: option.displayName,
                provider: route.provider.id, apiName: route.model
            )
        }
        return CleanupModel(
            selectionId: option.id, displayName: option.displayName,
            provider: OpenRouterService.providerID, apiName: option.id
        )
    }

    private static func providerID(of catalogID: String) -> String {
        String(catalogID.prefix { $0 != "/" })
    }
}
