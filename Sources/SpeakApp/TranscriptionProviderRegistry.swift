import Foundation
import SpeakCore

// MARK: - Provider Registry

actor TranscriptionProviderRegistry {
    static let shared = TranscriptionProviderRegistry()

    private var providers: [String: any TranscriptionProvider] = [:]

    /// Characterizes registered-instance ownership without constructing transports.
    init(providers: [String: any TranscriptionProvider]) {
        self.providers = providers
    }

    /// Comparisons inject a session owned by one lane; normal recording keeps the shared registry.
    init(session: URLSession = .shared, independentCleanup: Bool = false) {
        // Register all providers here - adding a new provider automatically makes it available
        providers["alibaba"] = AlibabaTranscriptionProvider(session: session)
        providers["azure"] = AzureTranscriptionProvider(session: session)
        providers["openai"] = OpenAITranscriptionProvider(session: session)
        providers["revai"] = RevAITranscriptionProvider(session: session)
        providers["deepgram"] = DeepgramTranscriptionProvider(session: session)
        providers["modulate"] = ModulateTranscriptionProvider(session: session)
        providers["assemblyai"] = AssemblyAITranscriptionProvider(session: session)
        providers["elevenlabs"] = ElevenLabsTranscriptionProvider(session: session)
        providers["soniox"] = SonioxTranscriptionProvider(session: session, independentCleanup: independentCleanup)
        providers["speechmatics"] = SpeechmaticsTranscriptionProvider(
            session: session, independentCleanup: independentCleanup
        )
        providers["groq"] = GroqTranscriptionProvider(session: session)
        providers["cartesia"] = CartesiaTranscriptionProvider(session: session)
        providers["mistral"] = MistralTranscriptionProvider(session: session)
        providers["gladia"] = GladiaTranscriptionProvider(session: session, independentCleanup: independentCleanup)
        providers["google"] = GeminiTranscriptionProvider(session: session)
        providers["xai"] = XAITranscriptionProvider(session: session)
        providers["meta"] = MetaMuseTranscriptionProvider(session: session)
        for provider in FileSpeechProvider.allCases {
            providers[provider.rawValue] = FileSpeechBatchClient(
                provider: provider, session: session,
                durationResolver: { url in
                    await resolvedTranscriptionDuration(reported: nil, lastSegmentEnd: nil, audioURL: url)
                }
            )
        }
    }

    func allProviders() -> [TranscriptionProviderMetadata] {
        providers.values.map { $0.metadata }.sorted { $0.displayName < $1.displayName }
    }

    func provider(withID id: String) -> (any TranscriptionProvider)? {
        providers[id]
    }

    func provider(forModel model: String) -> (any TranscriptionProvider)? {
        // Extract provider ID from model string (e.g., "openai/whisper-1" -> "openai")
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmedModel.split(separator: "/")
        guard let providerID = components.first else { return nil }
        guard let provider = providers[String(providerID)] else { return nil }
        // Alibaba owns the prefix, including invalid/retired selections. Its
        // client rejects those explicitly rather than uploading to OpenRouter.
        if providerID == "alibaba" { return provider }

        let supportedIDs = provider.supportedModels().map(\.id)
        // Live-only providers (e.g. Soniox) intentionally expose an empty batch
        // catalogue; treat that as "any model under this prefix is owned by us".
        if supportedIDs.isEmpty { return provider }
        guard supportedIDs.contains(trimmedModel) else { return nil }
        return provider
    }

    func allSupportedModels() -> [ModelCatalog.Option] {
        providers.values.flatMap { $0.supportedModels() }
    }

    func requiresAPIKey(for model: String) -> Bool {
        guard let provider = provider(forModel: model) else { return false }
        return provider.requiresAPIKey(for: model)
    }
}
