import Foundation

/// The cloud catalogue the Android app offers, as JSON, so Android never keeps its own copy of
/// model identifiers, names, wire fields, the cleanup and voice-edit prompts or the dictation profile
/// format.
///
/// Android uploads finished recordings over plain HTTPS to OpenAI, Reson8 and every provider whose
/// shared batch client iOS calls (`BatchTranscriptionRouting.iosSharedClientProviderIDs`), with
/// Kotlin clients that match those shared clients' wire formats. It uses OpenAI-compatible chat for
/// cleanup through every native text provider and OpenRouter. It offers every current batch model of
/// those transcription providers (only the models OpenAI's client sends directly), except models
/// with an announced retirement: Android has no saved-selection migration, so it never starts
/// offering a model that is about to shut down.
///
/// `CloudCatalogAndroidExportTests` fails when the committed asset is stale; regenerate it with
/// `UPDATE_CLOUD_CATALOG_ANDROID=1 swift test --filter CloudCatalogAndroidExportTests`.
public enum CloudCatalogAndroidExport {
    /// Providers whose batch transcription API Android implements, in settings order.
    static let transcriptionProviderIDs = [
        "openai", "groq", "assemblyai", "deepgram", "elevenlabs", "mistral", "modulate", "reson8", "revai",
        "soniox", "speechmatics"
    ]

    /// Providers Android reaches through OpenAI's `/audio/transcriptions` upload.
    static let openAICompatibleProviderIDs: Set<String> = ["openai", "groq"]

    /// The batch models Android offers, grouped in settings order and then in catalogue order, so
    /// OpenAI's model stays first: the first is Android's default.
    static var transcriptionModels: [ModelCatalog.Option] {
        let offered = ModelCatalog.batchTranscription.filter { option in
            let provider = providerID(of: option.id)
            guard transcriptionProviderIDs.contains(provider) else { return false }
            if provider == "openai", !OpenAITranscriptionModels.directBatchModelIDs.contains(option.id) {
                return false
            }
            return ModelRetirements.retirement(for: option.id) == nil
        }
        return transcriptionProviderIDs.flatMap { provider in offered.filter { providerID(of: $0.id) == provider } }
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
        /// The only language codes the model accepts, when it documents a fixed set (Reson8); an
        /// explicit language outside it fails before upload. Absent means any language.
        let languageCodes: [String]?
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

    /// `VoiceEditPolicy`'s prompt and the instruction words that keep requested formatting, so the
    /// Android keyboard's voice edit asks the model exactly what every other platform asks.
    private struct VoiceEdit: Encodable {
        let systemPrompt, userMessageIntro: String
        let quoteTerms, codeFenceTerms, whitespaceTerms: [String]
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

    /// One OpenRouter cleanup model as the browser lists and describes it
    /// (`OpenRouterModelBrowserCatalog.cleanupItems`), so Android shows the Mac's rows and details.
    private struct BrowserModel: Encodable {
        let selectionId, slug, name, provider, subtitle, summary, speed: String
        /// `ModelCatalog.Pricing.displayName`, when the catalogue lists rates.
        let pricing: String?
        let contextLength: Int?
        let strengths: [String]
        let hasZeroPrices: Bool
        let searchText: [String]
        let modelPageURL: String?
    }

    /// The **Browse OpenRouter models…** browser's shared copy and cleanup rows.
    private struct OpenRouterBrowser: Encodable {
        let browseButtonTitle, cleanupTitle, cleanupIntro, searchPlaceholder, allProvidersTitle: String
        let zeroPricesTitle, pricingCaveat, pricingUnlisted: String
        let useTitle, selectedTitle, routeNote: String
        let cleanupModels: [BrowserModel]
    }

    private struct Document: Encodable {
        let version: Int
        let providers: [Provider]
        let transcriptionModels: [Model]
        let cleanup: Cleanup
        let cleanupModels: [CleanupModel]
        /// Removed cleanup selections and the offered model each now uses.
        let cleanupModelSuccessors: [String: String]
        /// `TranscriptionLanguageCatalog.options`; the first is Automatic.
        let languages: [Language]
        let keywordPrompt: KeywordPrompt
        let profiles: Profiles
        let openRouterBrowser: OpenRouterBrowser
        let voiceEdit: VoiceEdit
    }

    public static func json() throws -> Data {
        let document = Document(
            version: 1,
            providers: providers,
            transcriptionModels: transcriptionModels.map(exported),
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
            ),
            openRouterBrowser: openRouterBrowser,
            voiceEdit: VoiceEdit(
                systemPrompt: VoiceEditPolicy.systemPrompt,
                userMessageIntro: VoiceEditPolicy.userMessageIntro,
                quoteTerms: VoiceEditFormattingIntent.quoteTerms,
                codeFenceTerms: VoiceEditFormattingIntent.codeFenceTerms,
                whitespaceTerms: VoiceEditFormattingIntent.whitespaceTerms
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    /// The credential identifiers Android stores, in settings order.
    static var providerCredentialIdentifiers: [String] { providers.map(\.credentialId) }

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
        // Every Android client sends the last path component as the model.
        let apiName = String(option.id.split(separator: "/").last ?? Substring(option.id))
        let provider = providerID(of: option.id)
        return Model(
            catalogId: option.id, displayName: option.displayName, provider: provider,
            apiName: apiName,
            languageField: OpenAITranscriptionModels.batchLanguageFieldName(for: apiName),
            // Only the OpenAI-compatible upload (OpenAI and Groq) has a `prompt` field; the other
            // providers take the vocabulary as their own keyterm fields.
            supportsPrompt: openAICompatibleProviderIDs.contains(provider)
                && OpenAITranscriptionModels.supportsBatchPrompt(apiName),
            languageCodes: Reson8Model(modelID: option.id).map { $0.languageCodes.sorted() }
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

    private static var openRouterBrowser: OpenRouterBrowser {
        typealias Browser = OpenRouterModelBrowserCatalog
        let models = Browser.cleanupItems(options: cleanupModels).map { item in
            let option = cleanupModels.first { $0.id == item.id }
            return BrowserModel(
                selectionId: item.id, slug: item.slug, name: item.name, provider: item.provider,
                subtitle: item.subtitle, summary: item.summary,
                speed: option?.latencyTier.displayName ?? "", pricing: item.pricing?.displayName,
                contextLength: item.contextLength, strengths: option?.tags.map(\.displayName) ?? [],
                hasZeroPrices: item.hasZeroPrices, searchText: item.searchText,
                modelPageURL: item.modelPageURL?.absoluteString
            )
        }
        return OpenRouterBrowser(
            browseButtonTitle: Browser.browseButtonTitle, cleanupTitle: Browser.title(for: .cleanup),
            cleanupIntro: Browser.intro(for: .cleanup), searchPlaceholder: Browser.searchPlaceholder,
            allProvidersTitle: Browser.allProvidersTitle, zeroPricesTitle: Browser.zeroPricesTitle,
            pricingCaveat: Browser.pricingCaveat,
            pricingUnlisted: Browser.pricingUnlisted,
            useTitle: Browser.actionTitle(for: .cleanup, selected: false),
            selectedTitle: Browser.actionTitle(for: .cleanup, selected: true),
            routeNote: Browser.routeNote(for: .cleanup), cleanupModels: models
        )
    }

    private static func providerID(of catalogID: String) -> String {
        String(catalogID.prefix { $0 != "/" })
    }
}
