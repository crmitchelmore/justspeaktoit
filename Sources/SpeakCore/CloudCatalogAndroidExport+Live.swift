import Foundation

/// The live (streaming) half of the Android cloud catalogue; see `CloudCatalogAndroidExport`.
extension CloudCatalogAndroidExport {
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

    struct LiveModel: Encodable {
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

    static func exportedLive(_ option: ModelCatalog.Option) -> LiveModel? {
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
}
