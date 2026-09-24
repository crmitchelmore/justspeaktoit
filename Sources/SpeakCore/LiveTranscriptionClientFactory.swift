import Foundation

// MARK: - Shared streaming client factory
//
// Split from `StreamingTranscriptionClient.swift` so the protocol, the provider
// enum and the routing stay readable as the provider list grows.

/// Constructs the shared streaming client for a resolved route.
///
/// Providers whose client already lives in `SpeakCore` are built here so both
/// platforms share one implementation. Providers without a shared client yet
/// (or on-device Apple, and OpenAI whose client is still platform-native)
/// return `nil` — callers fall back to a platform-native path or surface a
/// "not available yet" message.
public enum LiveTranscriptionClientFactory {
    public static func makeClient(
        for route: LiveTranscriptionRoute,
        apiKey: String,
        language: String?,
        keywords: [String] = []
    ) -> StreamingTranscriptionClient? {
        makeClient(
            for: route, apiKey: apiKey, language: language,
            options: LiveClientOptions(keywords: keywords)
        )
    }

    // The Azure Voice Live route also needs the resource endpoint the settings
    // store; every other provider ignores it. The original signature above is
    // kept as a forwarding overload so the exported API stays compatible.
    //
    // One case per provider is the point of this switch: the catalogue-to-transport
    // mapping stays auditable in one place, so its length grows with the provider list.
    public static func makeClient(
        for route: LiveTranscriptionRoute,
        apiKey: String,
        language: String?,
        keywords: [String],
        azureEndpoint: String
    ) -> StreamingTranscriptionClient? {
        makeClient(
            for: route, apiKey: apiKey, language: language,
            options: LiveClientOptions(keywords: keywords), azureEndpoint: azureEndpoint
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func makeClient(
        for route: LiveTranscriptionRoute,
        apiKey: String,
        language: String?,
        options: LiveClientOptions,
        azureEndpoint: String = ""
    ) -> StreamingTranscriptionClient? {
        switch route.provider {
        case .azure:
            return AzureVoiceLiveClient(credentials: apiKey, endpoint: azureEndpoint,
                                        model: route.apiModelName, language: language,
                                        sampleRate: route.sampleRate)
        case .deepgram:
            return DeepgramLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                sampleRate: route.sampleRate
            )
        case .elevenlabs:
            return ElevenLabsLiveClient(
                apiKey: apiKey,
                modelID: route.apiModelName,
                language: language,
                sampleRate: route.sampleRate
            )
        case .cartesia:
            return CartesiaLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                sampleRate: route.sampleRate
            )
        case .soniox:
            return SonioxLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                sampleRate: route.sampleRate
            )
        case .modulate:
            return ModulateLiveClient(
                apiKey: apiKey, sampleRate: route.sampleRate, options: options.modulate
            )
        case .assemblyai:
            let fallbackBudget = ModelCatalog.liveCapabilities(for: route.modelID)
                .postStopFinalizeBudget
            return AssemblyAILiveClient(
                apiKey: apiKey,
                speechModel: route.apiModelName,
                sampleRate: route.sampleRate,
                keyterms: options.assemblyAIKeyterms,
                postStopFinalizeBudget: options.postStopFinalizeBudget ?? fallbackBudget,
                stopGracePeriod: options.stopGracePeriod
            )
        case .gladia:
            return GladiaLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                sampleRate: route.sampleRate
            )
        case .google:
            return GeminiLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                customVocabulary: GeminiTranscribeModels.boundedCustomVocabulary(options.keywords),
                sampleRate: route.sampleRate
            )
        case .xai:
            return makeXAIClient(
                for: route, apiKey: apiKey, language: language, keywords: options.keywords
            )
        case .meta:
            return MetaMuseLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                keywords: options.keywords,
                sampleRate: route.sampleRate
            )
        case .speechmatics:
            return SpeechmaticsLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                sampleRate: route.sampleRate
            )
        case .revai:
            return RevAILiveClient(
                accessToken: apiKey,
                language: language,
                sampleRate: route.sampleRate
            )
        case .mistral:
            return MistralVoxtralLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                sampleRate: route.sampleRate
            )
        case .apple, .openai:
            return nil
        }
    }

    /// xAI serves two different realtime transports under one provider: the
    /// Grok Voice session used in transcription-only mode, and the dedicated
    /// speech-to-text socket. The catalogue identifier decides which, because
    /// they share neither protocol nor endpoint.
    private static func makeXAIClient(
        for route: LiveTranscriptionRoute,
        apiKey: String,
        language: String?,
        keywords: [String]
    ) -> StreamingTranscriptionClient {
        guard route.modelID != XAISpeechToText.liveCatalogID else {
            return XAISpeechToTextLiveClient(
                apiKey: apiKey,
                language: language,
                keywords: keywords,
                sampleRate: route.sampleRate
            )
        }
        return XAILiveClient(
            apiKey: apiKey,
            model: route.apiModelName,
            language: language,
            sampleRate: route.sampleRate
        )
    }
}
