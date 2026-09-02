import Foundation

/// Constructs the shared streaming client for a resolved route.
///
/// Providers whose client already lives in `SpeakCore` are built here so both
/// platforms share one implementation. Providers without a shared client yet
/// return `nil` so callers can use a platform-native path.
public enum LiveTranscriptionClientFactory {
    // One explicit case keeps the provider catalogue and concrete transport
    // mapping auditable in one place.
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
        case .xai:
            return XAILiveClient(
                apiKey: apiKey,
                model: route.apiModelName,
                language: language,
                sampleRate: route.sampleRate
            )
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
}
