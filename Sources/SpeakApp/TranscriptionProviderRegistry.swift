import Foundation
import SpeakCore

// MARK: - Provider Registry

actor TranscriptionProviderRegistry {
    static let shared = TranscriptionProviderRegistry()

    private var providers: [String: any TranscriptionProvider] = [:]

    private init() {
        // Register all providers here - adding a new provider automatically makes it available
        providers["openai"] = OpenAITranscriptionProvider()
        providers["revai"] = RevAITranscriptionProvider()
        providers["deepgram"] = DeepgramTranscriptionProvider()
        providers["modulate"] = ModulateTranscriptionProvider()
        providers["assemblyai"] = AssemblyAITranscriptionProvider()
        providers["elevenlabs"] = ElevenLabsTranscriptionProvider()
        providers["soniox"] = SonioxTranscriptionProvider()
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
