#if os(iOS)
import Combine
import Foundation
import SpeakCore

/// Provider-neutral voice-output boundary used by OpenClaw.
@MainActor
public final class VoiceOutputRouter: ObservableObject {
    @Published private(set) public var isSpeaking = false

    private let deepgram: DeepgramTTSClient
    private let soniox: SonioxIOSVoiceOutputClient
    private let openRouter: OpenRouterIOSVoiceOutputClient

    public init(session: URLSession = .shared) {
        self.deepgram = DeepgramTTSClient(session: session)
        self.soniox = SonioxIOSVoiceOutputClient(session: session)
        self.openRouter = OpenRouterIOSVoiceOutputClient(session: session)
        deepgram.$isSpeaking
            .combineLatest(soniox.$isSpeaking, openRouter.$isSpeaking)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .assign(to: &$isSpeaking)
    }

    public func speak( // swiftlint:disable:this function_parameter_count
        text: String,
        provider: VoiceOutputProvider,
        model: String,
        voice: String,
        lastKnownVoiceName: String?,
        speed: Double,
        languageIdentifier: String,
        sonioxRegion: SonioxTTSRegion,
        deepgramAPIKey: String,
        sonioxAPIKey: String,
        openRouterAPIKey: String = ""
    ) async throws {
        stop()
        switch provider {
        case .deepgram:
            deepgram.model = model
            deepgram.voice = voice
            deepgram.speed = min(max(speed, provider.speedRange.lowerBound), provider.speedRange.upperBound)
            try await deepgram.speak(text: text, apiKey: deepgramAPIKey)
        case .openrouter:
            try await openRouter.speak(text: text, apiKey: openRouterAPIKey, selectionID: model, speed: speed)
        case .soniox:
            try await soniox.speak(
                text: text,
                apiKey: sonioxAPIKey,
                voiceID: voice,
                lastKnownVoiceName: lastKnownVoiceName,
                languageIdentifier: languageIdentifier,
                region: sonioxRegion,
                speed: min(max(speed, provider.speedRange.lowerBound), provider.speedRange.upperBound)
            )
        }
    }

    public func listSonioxAccountVoices(
        apiKey: String,
        region: SonioxTTSRegion
    ) async throws -> [SonioxTTSAccountVoice] {
        try await soniox.listAccountVoices(apiKey: apiKey, region: region)
    }

    public func stop() {
        deepgram.stop()
        soniox.stop()
        openRouter.stop()
    }
}
#endif
