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
    // swiftlint:disable:next function_body_length
    public static func makeClient(
        for route: LiveTranscriptionRoute,
        apiKey: String,
        language: String?,
        keywords: [String] = []
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
            return ModulateLiveClient(apiKey: apiKey, sampleRate: route.sampleRate)
        case .assemblyai:
            return AssemblyAILiveClient(
                apiKey: apiKey,
                speechModel: route.apiModelName,
                sampleRate: route.sampleRate
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
                sampleRate: route.sampleRate
            )
        case .xai:
            return makeXAIClient(for: route, apiKey: apiKey, language: language)
        case .meta:
            return MetaMuseLiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                keywords: keywords,
                sampleRate: route.sampleRate
            )
        case .apple, .openai, .speechmatics:
            return nil
        }
    }

    private static func makeXAIClient(
        for route: LiveTranscriptionRoute,
        apiKey: String,
        language: String?
    ) -> XAILiveClient {
        XAILiveClient(
            apiKey: apiKey,
            model: route.apiModelName,
            language: language,
            sampleRate: route.sampleRate
        )
    }
}
