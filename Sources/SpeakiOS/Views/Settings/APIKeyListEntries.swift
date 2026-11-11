#if os(iOS)
import SpeakCore

/// The providers the API Keys screen lists, each with whether its key is
/// stored and whether its last save was rejected.
@MainActor
enum APIKeyListEntries {
    static func all(for settings: AppSettings, failedEntryIDs: Set<String>) -> [APIKeyListEntry] {
        let entries = coreEntries(for: settings) + streamingProviderEntries(for: settings)
            + FileSpeechProvider.allCases.map {
                APIKeyListEntry(
                    id: $0.rawValue, title: $0.metadata.displayName, category: "Transcription",
                    isStored: settings.storedAPIKeyIdentifiers.contains($0.metadata.apiKeyIdentifier)
                )
            }
        guard !failedEntryIDs.isEmpty else { return entries }
        return entries.map { entry in
            APIKeyListEntry(
                id: entry.id, title: entry.title, category: entry.category, isStored: entry.isStored,
                hasError: failedEntryIDs.contains(entry.id)
            )
        }
    }

    private static func coreEntries(for settings: AppSettings) -> [APIKeyListEntry] {
        [
            APIKeyListEntry(
                id: "deepgram", title: "Deepgram", category: "Transcription", isStored: settings.hasDeepgramKey
            ),
            APIKeyListEntry(
                id: "elevenlabs", title: "ElevenLabs", category: "Transcription & Voice Output",
                isStored: settings.hasElevenLabsKey
            ),
            APIKeyListEntry(
                id: "openrouter", title: "OpenRouter", category: "Post-processing", isStored: settings.hasOpenRouterKey
            ),
            APIKeyListEntry(
                id: "openai", title: "OpenAI", category: "Transcription", isStored: settings.hasOpenAIKey
            ),
            APIKeyListEntry(
                id: "cartesia", title: "Cartesia", category: "Transcription", isStored: settings.hasCartesiaKey
            ),
            APIKeyListEntry(
                id: "soniox", title: "Soniox", category: "Transcription & Voice Output",
                isStored: settings.hasSonioxKey
            ),
            APIKeyListEntry(
                id: "modulate", title: "Modulate", category: "Transcription", isStored: settings.hasModulateKey
            ),
            APIKeyListEntry(
                id: "assemblyai", title: "AssemblyAI", category: "Transcription",
                isStored: settings.hasAssemblyAIKey
            ),
            APIKeyListEntry(
                id: "gladia", title: "Gladia", category: "Transcription", isStored: settings.hasGladiaKey
            ),
            APIKeyListEntry(
                id: "google", title: GeminiTranscribeModels.providerDisplayName,
                category: "Transcription", isStored: settings.hasGoogleKey
            )
        ]
    }

    private static func streamingProviderEntries(for settings: AppSettings) -> [APIKeyListEntry] {
        [
            APIKeyListEntry(
                id: "alibaba", title: "Alibaba Model Studio", category: "Transcription",
                isStored: settings.hasAlibabaKey
            ),
            APIKeyListEntry(
                id: "xai", title: "xAI", category: "Transcription", isStored: settings.hasXAIKey
            ),
            APIKeyListEntry(
                id: "meta", title: "Meta", category: "Transcription", isStored: settings.hasMetaKey
            ),
            APIKeyListEntry(
                id: "speechmatics", title: "Speechmatics", category: "Transcription & Voice Output",
                isStored: settings.hasSpeechmaticsKey
            ),
            APIKeyListEntry(
                id: "revai", title: "Rev.ai", category: "Transcription", isStored: settings.hasRevAIKey
            ),
            APIKeyListEntry(
                id: "mistral", title: "Mistral", category: "Transcription & Voice Output",
                isStored: settings.hasMistralKey
            ),
            APIKeyListEntry(
                id: "azure", title: "Azure Speech", category: "Transcription", isStored: settings.hasAzureKey
            ),
            APIKeyListEntry(
                id: "anthropic", title: "Anthropic", category: "Post-processing", isStored: settings.hasAnthropicKey
            )
        ]
    }
}
#endif
