#if os(iOS)
import SpeakCore

/// How one provider's card on the API Keys screen is labelled.
struct APIKeyProviderPresentation: Equatable {
    let title: String
    let systemImage: String
    let help: String

    /// File-speech providers describe themselves; any other unknown id is the
    /// Gladia card, as it always has been.
    init(entryID id: String) {
        if let provider = FileSpeechProvider(rawValue: id) {
            self.init(
                title: provider.metadata.displayName, systemImage: provider.metadata.systemImage,
                help: "Get your key from \(provider.metadata.website). Access is checked when transcribing."
            )
        } else {
            self = Self.byEntryID[id] ?? Self.gladia
        }
    }

    private init(title: String, systemImage: String, help: String) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
    }

    private static let gladia = APIKeyProviderPresentation(
        title: "Gladia", systemImage: "waveform.badge.exclamationmark", help: "Get your key from gladia.io."
    )

    private static let byEntryID: [String: APIKeyProviderPresentation] = [
        "deepgram": APIKeyProviderPresentation(
            title: "Deepgram",
            systemImage: "waveform",
            help: "Get your key from deepgram.com."
        ),
        "elevenlabs": APIKeyProviderPresentation(
            title: "ElevenLabs", systemImage: "mic.and.signal.meter", help: "Get your key from elevenlabs.io."
        ),
        "openrouter": APIKeyProviderPresentation(
            title: "OpenRouter",
            systemImage: "network",
            help: "Get your key from openrouter.ai."
        ),
        "openai": APIKeyProviderPresentation(
            title: "OpenAI", systemImage: "brain.head.profile", help: "Get your key from platform.openai.com."
        ),
        "cartesia": APIKeyProviderPresentation(
            title: "Cartesia", systemImage: "waveform.circle", help: "Get your key from cartesia.ai."
        ),
        "soniox": APIKeyProviderPresentation(
            title: "Soniox", systemImage: "waveform.badge.mic", help: "Get your key from soniox.com."
        ),
        "modulate": APIKeyProviderPresentation(
            title: "Modulate", systemImage: "waveform.badge.magnifyingglass", help: "Get your key from modulate.ai."
        ),
        "assemblyai": APIKeyProviderPresentation(
            title: "AssemblyAI", systemImage: "waveform.badge.plus", help: "Get your key from assemblyai.com."
        ),
        "google": APIKeyProviderPresentation(
            title: GeminiTranscribeModels.providerDisplayName, systemImage: "sparkles",
            help: "Get your key from aistudio.google.com."
        ),
        "xai": APIKeyProviderPresentation(
            title: "xAI", systemImage: "waveform.badge.mic", help: "Get your key from console.x.ai."
        ),
        "azure": APIKeyProviderPresentation(
            title: "Azure Speech", systemImage: "cloud",
            help: "Enter your Azure key and region as key:region."
        ),
        "alibaba": APIKeyProviderPresentation(
            title: "Alibaba Model Studio", systemImage: "waveform",
            help: "Choose the matching region and workspace above, then enter its Model Studio API key. "
                + "Access is checked when transcribing; no cross-region retry."
        ),
        "meta": APIKeyProviderPresentation(
            title: "Meta", systemImage: "waveform.badge.mic",
            help: "Get your Model API key from llama.developer.meta.com."
        ),
        "speechmatics": APIKeyProviderPresentation(
            title: "Speechmatics", systemImage: "waveform.and.magnifyingglass",
            help: "Get your key from portal.speechmatics.com."
        ),
        "revai": APIKeyProviderPresentation(
            title: "Rev.ai", systemImage: "waveform.badge.mic",
            help: "Get your access token from www.rev.ai."
        ),
        "mistral": APIKeyProviderPresentation(
            title: "Mistral", systemImage: "waveform.circle",
            help: "Get your key from console.mistral.ai."
        ),
        "anthropic": APIKeyProviderPresentation(
            title: "Anthropic", systemImage: "text.badge.checkmark",
            help: "Get your key from platform.claude.com. Used for Claude cleanup models."
        )
    ]
}
#endif
