import Foundation

/// The operation a model is selected for. The same catalogue identifier can
/// use a different credential depending on the operation (for example OpenAI
/// models routed through OpenRouter for post-processing).
public enum ModelCredentialPurpose: Sendable {
    case liveTranscription
    case batchTranscription
    case postProcessing
    case voiceOutput
}

/// The credential a model needs before it can run.
public enum ModelCredentialRequirement: Equatable, Sendable {
    case notRequired
    case apiKey(identifier: String, providerName: String)
}

/// User-facing readiness derived from a model requirement and the identifiers
/// currently stored in secure storage.
public enum ModelCredentialAvailability: Equatable, Sendable {
    case ready(providerName: String)
    case missing(providerName: String)
    case notRequired
}

/// Canonical model-to-credential mapping shared by the macOS and iOS pickers.
/// Runtime clients remain authoritative for requests; this resolver keeps the
/// selection UX in sync with those routing rules.
public enum ModelCredentialResolver {
    public static func requirement(
        for modelIdentifier: String,
        purpose: ModelCredentialPurpose
    ) -> ModelCredentialRequirement {
        let trimmed = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        switch purpose {
        case .liveTranscription:
            return liveTranscriptionRequirement(for: trimmed)
        case .batchTranscription:
            return batchTranscriptionRequirement(for: trimmed)
        case .postProcessing:
            return postProcessingRequirement(for: trimmed)
        case .voiceOutput:
            return voiceOutputRequirement(for: trimmed)
        }
    }

    public static func availability(
        for modelIdentifier: String,
        purpose: ModelCredentialPurpose,
        storedAPIKeyIdentifiers: some Sequence<String>
    ) -> ModelCredentialAvailability {
        let stored = Set(storedAPIKeyIdentifiers)
        switch requirement(for: modelIdentifier, purpose: purpose) {
        case .notRequired:
            return .notRequired
        case .apiKey(let identifier, let providerName):
            return stored.contains(identifier)
                ? .ready(providerName: providerName)
                : .missing(providerName: providerName)
        }
    }

    private static func liveTranscriptionRequirement(for modelIdentifier: String) -> ModelCredentialRequirement {
        guard let route = LiveTranscriptionRouting.route(for: modelIdentifier) else {
            return requirementForProviderPrefix(modelIdentifier, fallbackProvider: nil)
        }
        guard let identifier = route.apiKeyIdentifier else { return .notRequired }
        return .apiKey(identifier: identifier, providerName: route.provider.displayName)
    }

    private static func batchTranscriptionRequirement(for modelIdentifier: String) -> ModelCredentialRequirement {
        if modelIdentifier == ModelCatalog.customOptionID {
            return openRouterRequirement
        }
        if isLocal(modelIdentifier) {
            return .notRequired
        }

        // These models use OpenAI's own audio transcription endpoint. Other
        // OpenAI-prefixed audio models in the batch catalogue are OpenRouter
        // models, so an identifier prefix alone is not sufficient here.
        if openAIBatchModelIdentifiers.contains(modelIdentifier) {
            return .apiKey(identifier: "openai.apiKey", providerName: "OpenAI")
        }

        let provider = providerPrefix(in: modelIdentifier)
        if directBatchProviderIdentifiers.contains(provider) {
            return .apiKey(
                identifier: "\(provider).apiKey",
                providerName: providerDisplayName(provider)
            )
        }
        return openRouterRequirement
    }

    private static func postProcessingRequirement(for modelIdentifier: String) -> ModelCredentialRequirement {
        if isLocal(modelIdentifier) {
            return .notRequired
        }
        return openRouterRequirement
    }

    private static func voiceOutputRequirement(for modelIdentifier: String) -> ModelCredentialRequirement {
        let lowered = modelIdentifier.lowercased()
        if isLocal(lowered) || lowered.hasPrefix("system/") || lowered == "system" {
            return .notRequired
        }
        if lowered.hasPrefix("aura") || lowered.hasPrefix("deepgram/") {
            return .apiKey(identifier: "deepgram.apiKey", providerName: "Deepgram")
        }
        if lowered.hasPrefix("elevenlabs/") {
            return .apiKey(identifier: "elevenlabs.apiKey", providerName: "ElevenLabs")
        }
        if lowered.hasPrefix("openai/") {
            return .apiKey(identifier: "openai.tts.apiKey", providerName: "OpenAI")
        }
        if lowered.hasPrefix("azure/") {
            return .apiKey(identifier: "azure.speech.apiKey", providerName: "Azure")
        }
        return requirementForProviderPrefix(lowered, fallbackProvider: nil)
    }

    private static func requirementForProviderPrefix(
        _ modelIdentifier: String,
        fallbackProvider: String?
    ) -> ModelCredentialRequirement {
        let provider = providerPrefix(in: modelIdentifier)
        guard !provider.isEmpty, provider != ModelCatalog.customOptionID else {
            guard let fallbackProvider else { return .notRequired }
            return .apiKey(
                identifier: "\(fallbackProvider).apiKey",
                providerName: providerDisplayName(fallbackProvider)
            )
        }
        if provider == "apple" || provider == "local" || provider == "system" {
            return .notRequired
        }
        return .apiKey(
            identifier: "\(provider).apiKey",
            providerName: providerDisplayName(provider)
        )
    }

    private static func isLocal(_ modelIdentifier: String) -> Bool {
        let lowered = modelIdentifier.lowercased()
        return lowered.hasPrefix("apple/")
            || lowered.hasPrefix("local/")
            || lowered.hasPrefix("system/")
    }

    private static func providerPrefix(in modelIdentifier: String) -> String {
        modelIdentifier
            .split(separator: "/", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? ""
    }

    private static func providerDisplayName(_ provider: String) -> String {
        providerDisplayNames[provider] ?? provider.capitalized
    }

    private static let providerDisplayNames = [
        "assemblyai": "AssemblyAI",
        "deepgram": "Deepgram",
        "elevenlabs": "ElevenLabs",
        "gladia": "Gladia",
        "groq": "Groq",
        "mistral": "Mistral",
        "modulate": "Modulate",
        "openai": "OpenAI",
        "openrouter": "OpenRouter",
        "revai": "Rev.ai",
        "soniox": "Soniox",
        "speechmatics": "Speechmatics"
    ]

    private static let openRouterRequirement = ModelCredentialRequirement.apiKey(
        identifier: "openrouter.apiKey",
        providerName: "OpenRouter"
    )

    private static let openAIBatchModelIdentifiers: Set<String> = [
        "openai/whisper-1",
        "openai/gpt-4o-mini-transcribe",
        "openai/gpt-4o-transcribe",
        "openai/gpt-4o-transcribe-diarize"
    ]

    private static let directBatchProviderIdentifiers: Set<String> = [
        "assemblyai",
        "deepgram",
        "elevenlabs",
        "gladia",
        "groq",
        "mistral",
        "modulate",
        "revai",
        "soniox",
        "speechmatics"
    ]
}
