import Foundation

// MARK: - Providers and routing
//
// The canonical provider list and the model-id -> provider/route mapping used by
// the shared streaming clients. Split out of `StreamingTranscriptionClient.swift`
// to keep both files inside the project's 400-line budget; the client protocols
// and error types remain there.

/// The set of live streaming transcription providers the app knows about.
///
/// This is the canonical list; `ModelCatalog.liveTranscription` supplies the
/// user-facing models and `LiveTranscriptionRouting` maps each model id onto one
/// of these providers.
public enum LiveTranscriptionProviderID: String, Sendable, CaseIterable, Hashable {
    case apple
    case azure
    case deepgram
    case cartesia
    case gladia
    case google
    case modulate
    case assemblyai
    case soniox
    case elevenlabs
    case openai
    case speechmatics
    case xai
    case meta
    case revai
    case mistral

    /// Keychain identifier for this provider's API key, or `nil` for on-device
    /// providers that need no credential. Matches the identifiers used by both
    /// platforms' secure storage (e.g. `deepgram.apiKey`).
    public var apiKeyIdentifier: String? {
        switch self {
        case .apple:
            return nil
        case .azure:
            return AzureSpeechConfiguration.credentialIdentifier
        case .openai:
            return "openai.apiKey"
        default:
            return "\(rawValue).apiKey"
        }
    }

    /// PCM sample rate (Hz) the provider's streaming client expects.
    public var expectedSampleRate: Int {
        switch self {
        case .openai, .xai, .meta, .azure:
            // OpenAI, xAI and Meta realtime transcription ingest 24 kHz PCM16.
            return 24_000
        default:
            return 16_000
        }
    }

    /// Whether the iOS app currently has a working path (shared client or
    /// native transcriber) for this provider. The iOS model picker uses this to
    /// distinguish selectable models from ones that are catalogued but not yet
    /// wired up on iOS. Flip a case to `true` in the same change that adds the
    /// iOS path so the two never drift.
    ///
    /// Every case is `true` today: each cloud provider is driven by a shared
    /// `StreamingTranscriptionClient` (or, for Apple and OpenAI, a native
    /// transcriber that both platforms have), so there is nothing the Mac can
    /// stream that the iPhone cannot. The property stays because it is the
    /// seam a newly catalogued, macOS-only provider would use.
    public var isSupportedOnIOS: Bool {
        switch self {
        case .apple, .deepgram, .elevenlabs, .openai, .cartesia, .soniox, .modulate, .assemblyai,
             .gladia, .google, .xai, .meta, .speechmatics, .revai, .mistral, .azure:
            return true
        }
    }

    /// Human-readable provider name, used to group models by provider in the
    /// model picker so the UI scales cleanly as models are added.
    public var displayName: String {
        switch self {
        case .azure: return "Azure Speech"
        case .apple: return "Apple"
        case .deepgram: return "Deepgram"
        case .cartesia: return "Cartesia"
        case .gladia: return "Gladia"
        case .google: return GeminiTranscribeModels.providerDisplayName
        case .modulate: return "Modulate"
        case .assemblyai: return "AssemblyAI"
        case .soniox: return "Soniox"
        case .elevenlabs: return "ElevenLabs"
        case .openai: return "OpenAI"
        case .speechmatics: return "Speechmatics"
        case .xai: return "xAI"
        case .meta: return "Meta"
        case .revai: return "Rev.ai"
        case .mistral: return "Mistral"
        }
    }

    /// Sign-up/console page where the user can create this provider's API
    /// key, or `nil` for on-device providers. Both platforms' "API key
    /// required" alerts derive their "Get API Key" link from this so the
    /// provider metadata never drifts between Mac and iPhone.
    public var apiKeyURL: URL? {
        let website: String
        switch self {
        case .azure: website = "https://portal.azure.com"
        case .apple: return nil
        case .deepgram: website = "https://deepgram.com"
        case .cartesia: website = "https://cartesia.ai"
        case .gladia: website = "https://www.gladia.io"
        case .google: website = "https://aistudio.google.com/apikey"
        case .modulate: website = "https://www.modulate-developer-apis.com/web/docs.html"
        case .assemblyai: website = "https://assemblyai.com"
        case .soniox: website = "https://soniox.com"
        case .elevenlabs: website = "https://elevenlabs.io"
        case .openai: website = "https://platform.openai.com"
        case .speechmatics: website = "https://www.speechmatics.com"
        case .xai: website = "https://console.x.ai"
        case .meta: website = "https://llama.developer.meta.com"
        case .revai: website = "https://www.rev.ai"
        case .mistral: website = "https://console.mistral.ai"
        }
        return URL(string: website)
    }
}

// MARK: - Routing

/// Resolves a catalog live-model id (e.g. `deepgram/nova-3-streaming`) to the
/// concrete provider and the provider's own API model name (e.g. `nova-3`).
///
/// Centralising this mapping means both platforms translate model ids the same
/// way, and the `-streaming` suffix convention used by the catalog never leaks
/// into a provider request.
public struct LiveTranscriptionRoute: Sendable, Hashable {
    public let modelID: String
    public let provider: LiveTranscriptionProviderID
    public let apiModelName: String
    public let sampleRate: Int

    public init(
        modelID: String,
        provider: LiveTranscriptionProviderID,
        apiModelName: String,
        sampleRate: Int
    ) {
        self.modelID = modelID
        self.provider = provider
        self.apiModelName = apiModelName
        self.sampleRate = sampleRate
    }

    /// Keychain identifier for the API key this route needs, if any.
    public var apiKeyIdentifier: String? { provider.apiKeyIdentifier }

    /// Whether iOS can run this model today.
    public var isSupportedOnIOS: Bool { provider.isSupportedOnIOS }
}

public enum LiveTranscriptionRouting {
    /// Resolves a catalog live-model id to its route, or `nil` if the id does
    /// not belong to a known live-transcription provider.
    public static func route(for modelID: String) -> LiveTranscriptionRoute? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let prefix = String(trimmed[trimmed.startIndex..<slash]).lowercased()
        guard let provider = LiveTranscriptionProviderID(rawValue: prefix) else { return nil }

        return LiveTranscriptionRoute(
            modelID: trimmed,
            provider: provider,
            apiModelName: apiModelName(for: trimmed, provider: provider),
            sampleRate: provider.expectedSampleRate
        )
    }

    /// All routes for the models the catalogue exposes, in catalogue order.
    /// Derived from `ModelCatalog.liveTranscription` so the two never drift.
    public static var allRoutes: [LiveTranscriptionRoute] {
        ModelCatalog.liveTranscription.compactMap { route(for: $0.id) }
    }

    /// Resolves the model that can actually start with the supplied credential.
    /// On-device routes never need a credential. A cloud route with a missing
    /// or blank API key falls back to the shared on-device default so every
    /// platform applies the same safe startup behavior.
    public static func resolvedModelID(for modelID: String, apiKey: String?) -> String {
        guard let route = route(for: modelID) else {
            return modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard route.apiKeyIdentifier != nil else { return route.modelID }
        guard !(apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ModelCatalog.defaultOnDeviceLiveTranscriptionModel
        }
        return route.modelID
    }

    /// Translates a catalog id into the provider's own API model name.
    ///
    /// The general rule strips the `provider/` prefix and the `-streaming`
    /// suffix (the catalogue's convention). A few providers name their model
    /// differently from the catalogue and are special-cased.
    static func apiModelName(for modelID: String, provider: LiveTranscriptionProviderID) -> String {
        var name = modelID
        if let slash = name.firstIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.hasSuffix("-streaming") {
            name = String(name.dropLast("-streaming".count))
        }

        switch provider {
        case .elevenlabs:
            // The catalogue exposes `elevenlabs/scribe-v2-streaming`, but the
            // ElevenLabs realtime API model id is `scribe_v2_realtime`.
            if name == "scribe-v2" { return "scribe_v2_realtime" }
            return name
        case .apple:
            // Apple ids are used as-is by the on-device transcriber.
            return modelID
        default:
            return name
        }
    }
}
