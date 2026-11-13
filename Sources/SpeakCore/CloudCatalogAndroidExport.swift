import Foundation

/// The cloud catalogue the Android app offers, as JSON, so Android never keeps its own copy of
/// model identifiers, names, wire fields, the cleanup prompt or the dictation profile format.
///
/// Android implements OpenAI-compatible `/audio/transcriptions` uploads for OpenAI and Groq, and
/// OpenAI-compatible chat for cleanup through every native text provider and OpenRouter. It
/// therefore offers every current batch model of those transcription providers that OpenAI's
/// client sends directly (Groq reuses that client), except models with an announced retirement:
/// Android has no saved-selection migration, so it never starts offering a model that is about to
/// shut down.
///
/// Android also streams the live routes whose protocols it implements natively (Deepgram,
/// AssemblyAI Universal-3.6 Pro and OpenAI Realtime), with the canonical identifiers, sample rates,
/// language-hint and vocabulary fields and post-stop finalise budgets, so the Kotlin clients never
/// keep a second list. Retired live models are not offered, for the same reason as batch models.
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

    /// Live providers whose WebSocket protocol Android implements, in catalogue order.
    static let liveProviderIDs: Set<LiveTranscriptionProviderID> = [.deepgram, .assemblyai, .openai]

    /// The live models Android streams, in catalogue order: every current route of an Android live
    /// provider. A new route of one of these providers appears on Android without edits here.
    static var liveTranscriptionModels: [ModelCatalog.Option] {
        ModelCatalog.liveTranscription.filter { option in
            guard let route = LiveTranscriptionRouting.route(for: option.id),
                  liveProviderIDs.contains(route.provider) else { return false }
            return ModelRetirements.retirement(for: option.id) == nil
        }
    }

    /// Cleanup models Android offers, in catalogue order: native provider routes, then OpenRouter
    /// slugs. On-device and Apple cleanup engines are Mac-only.
    static var cleanupModels: [ModelCatalog.Option] { ModelCatalog.cloudPostProcessing }

    /// Every removed cleanup selection whose successor Android offers, so a saved choice
    /// keeps its provider and key instead of falling back to the default route.
    static var cleanupModelSuccessors: [String: String] {
        let offered = Set(cleanupModels.map(\.id))
        return Dictionary(
            CleanupModelRemovals.all.compactMap { removal in
                let successor = ModelCatalog.currentPostProcessingModel(removal.successorID)
                return offered.contains(successor) ? (removal.id, successor) : nil
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private struct Provider: Encodable {
        let id, credentialId: String
        /// Native text providers only: the cleanup endpoint, which Android's transport must match.
        let chatCompletionsURL: String?
    }

    private struct Model: Encodable {
        let catalogId, displayName, provider, apiName, languageField: String
        /// Whether the model takes the vocabulary glossary as its `prompt` field.
        let supportsPrompt: Bool
    }

    private struct LiveModel: Encodable {
        let catalogId, displayName, provider, apiName: String
        let sampleRate: Int
        /// The wire field for the spoken-language hint, or empty when the route takes none.
        let languageField: String
        /// The wire field for the vocabulary (`prompt`, `keyterm`, `keywords`, `keyterms_prompt`),
        /// or empty when the route takes none.
        let vocabularyField: String
        /// `LiveModelCapabilities.postStopFinalizeBudget`, in milliseconds.
        let postStopFinalizeBudgetMs: Int
    }

    private struct Language: Encodable {
        let id, displayName: String
    }

    /// `TranscriptionKeywordPolicy.prompt` bounds, so Android builds the same glossary.
    private struct KeywordPrompt: Encodable {
        let maximumBytes, maximumTerms: Int
    }

    private struct Cleanup: Encodable {
        let provider, model, systemPrompt: String
        /// The section that ends a prompt built on the user's own base prompt.
        let customPromptClosing: String
    }

    /// Where and how Android stores `DictationProfile`s, so its profiles keep the shared shape.
    private struct Profiles: Encodable {
        let storageKey: String
        /// The routing Android writes for a profile's cloud model: it only uploads finished recordings.
        let cloudTranscriptionRouting: String
        /// `DictationProfile`'s JSON field names; Android writes only these.
        let fields: [String]
    }

    private struct CleanupModel: Encodable {
        let selectionId, displayName, provider, apiName: String
    }

    private struct Document: Encodable {
        let version: Int
        let providers: [Provider]
        let transcriptionModels: [Model]
        let liveTranscriptionModels: [LiveModel]
        let cleanup: Cleanup
        let cleanupModels: [CleanupModel]
        /// Removed cleanup selections and the offered model each now uses.
        let cleanupModelSuccessors: [String: String]
        /// `TranscriptionLanguageCatalog.options`; the first is Automatic.
        let languages: [Language]
        let keywordPrompt: KeywordPrompt
        let profiles: Profiles
    }

    public static func json() throws -> Data {
        let document = Document(
            version: 1,
            providers: providers,
            transcriptionModels: transcriptionModels.map(exported),
            liveTranscriptionModels: liveTranscriptionModels.compactMap(exportedLive),
            cleanup: Cleanup(
                provider: OpenRouterService.providerID,
                model: ModelCatalog.defaultPostProcessingModel,
                systemPrompt: TranscriptCleanupPolicy.systemPrompt(),
                customPromptClosing: TranscriptCleanupPolicy.customPromptClosing
            ),
            cleanupModels: cleanupModels.map(exportedCleanup),
            cleanupModelSuccessors: cleanupModelSuccessors,
            languages: TranscriptionLanguageCatalog.options.map { Language(id: $0.id, displayName: $0.displayName) },
            keywordPrompt: KeywordPrompt(
                maximumBytes: TranscriptionKeywordPolicy.promptMaximumCharacters,
                maximumTerms: TranscriptionKeywordPolicy.promptMaximumTerms
            ),
            profiles: Profiles(
                storageKey: DataMigrationProfileCatalog.defaultsKey,
                cloudTranscriptionRouting: DictationProfileTranscriptionRouting.remoteBatch.rawValue,
                fields: DictationProfile.CodingKeys.allCases.map(\.rawValue)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    /// Transcription providers, then OpenRouter, then the remaining native text providers.
    private static var providers: [Provider] {
        var ids = transcriptionProviderIDs
        for id in liveTranscriptionModels.map({ providerID(of: $0.id) }) where !ids.contains(id) {
            ids.append(id)
        }
        ids.append(OpenRouterService.providerID)
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
            languageField: OpenAITranscriptionModels.batchLanguageFieldName(for: apiName),
            supportsPrompt: OpenAITranscriptionModels.supportsBatchPrompt(apiName)
        )
    }

    private static func exportedLive(_ option: ModelCatalog.Option) -> LiveModel? {
        guard let route = LiveTranscriptionRouting.route(for: option.id) else { return nil }
        let capabilities = ModelCatalog.liveCapabilities(for: option.id)
        let api = route.apiModelName
        let languageField: String
        let vocabularyField: String
        switch route.provider {
        case .openai:
            languageField = OpenAITranscriptionModels.usesLanguageHintsArray(api) ? "languages" : "language"
            vocabularyField = OpenAITranscriptionModels.supportsRealtimePrompt(api) ? "prompt" : ""
        case .deepgram:
            languageField = api == "flux-general-multi" ? "language_hint" : "language"
            vocabularyField = TranscriptionKeywordPolicy.deepgramQuery(model: api, words: ["x"]).first?.name ?? ""
        default:
            languageField = ""
            vocabularyField = "keyterms_prompt"
        }
        return LiveModel(
            catalogId: option.id, displayName: option.displayName, provider: route.provider.rawValue,
            apiName: api, sampleRate: route.sampleRate,
            languageField: capabilities.supportsLanguageHint ? languageField : "",
            vocabularyField: vocabularyField,
            postStopFinalizeBudgetMs: Int((capabilities.postStopFinalizeBudget * 1000).rounded())
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
