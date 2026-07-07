import Foundation

// MARK: - Shared streaming transcription client pattern
//
// Every cloud live-transcription provider is driven by a single, cross-platform
// WebSocket client that conforms to `StreamingTranscriptionClient`. Both the
// macOS app and the iOS app feed the same client PCM audio captured by their
// own (platform-specific) capture layer, so a provider is implemented once and
// works everywhere. New providers/models added to `ModelCatalog.liveTranscription`
// become available on both platforms as soon as their client is registered here.

/// A provider-agnostic live streaming transcription client.
///
/// Implementations own a single WebSocket session: `start` opens it, `sendAudio`
/// streams linear16 mono PCM at the provider's expected sample rate (see
/// `LiveTranscriptionRoute.sampleRate`), and `stop` tears it down. Transcript
/// updates and errors are delivered through the closures passed to `start`.
public protocol StreamingTranscriptionClient: AnyObject {
    /// Opens the session.
    /// - Parameters:
    ///   - onTranscript: `(text, isFinal)` for each interim/final transcript.
    ///   - onError: terminal or recoverable transport error.
    func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    )

    /// Streams a chunk of linear16 mono PCM audio.
    func sendAudio(_ audioData: Data)

    /// Closes the session and releases resources.
    func stop()
}

// MARK: - Providers

/// The set of live streaming transcription providers the app knows about.
///
/// This is the canonical list; `ModelCatalog.liveTranscription` supplies the
/// user-facing models and `LiveTranscriptionRouting` maps each model id onto one
/// of these providers.
public enum LiveTranscriptionProviderID: String, Sendable, CaseIterable, Hashable {
    case apple
    case deepgram
    case cartesia
    case gladia
    case modulate
    case assemblyai
    case soniox
    case elevenlabs
    case openai

    /// Keychain identifier for this provider's API key, or `nil` for on-device
    /// providers that need no credential. Matches the identifiers used by both
    /// platforms' secure storage (e.g. `deepgram.apiKey`).
    public var apiKeyIdentifier: String? {
        switch self {
        case .apple:
            return nil
        case .openai:
            return "openai.apiKey"
        default:
            return "\(rawValue).apiKey"
        }
    }

    /// PCM sample rate (Hz) the provider's streaming client expects.
    public var expectedSampleRate: Int {
        switch self {
        case .openai:
            // OpenAI's Realtime transcription API ingests 24 kHz PCM16.
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
    public var isSupportedOnIOS: Bool {
        switch self {
        case .apple, .deepgram, .elevenlabs, .openai:
            return true
        case .cartesia, .gladia, .modulate, .assemblyai, .soniox:
            return false
        }
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

// MARK: - Factory

public enum LiveTranscriptionClientError: LocalizedError {
    case unknownModel(String)
    case providerNotAvailable(LiveTranscriptionProviderID)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id):
            return "Unrecognised transcription model: \(id)."
        case .providerNotAvailable(let provider):
            return "\(provider.rawValue.capitalized) live transcription isn't available on this device yet."
        }
    }
}

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
        language: String?
    ) -> StreamingTranscriptionClient? {
        switch route.provider {
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
                language: language
            )
        case .apple, .openai, .cartesia, .gladia, .modulate, .assemblyai, .soniox:
            return nil
        }
    }
}
