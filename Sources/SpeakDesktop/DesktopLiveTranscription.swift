import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Live providers implemented by the shared desktop session. Hosts must also
/// qualify their native transport before exposing this projection in the UI.
/// Models, routing and credential metadata remain owned by SpeakCore.
public enum DesktopLiveTranscription {
    /// The live routes the shared desktop session implements. xAI serves two
    /// live products under one provider and only the dedicated speech-to-text
    /// stream has a shared client, so that route is admitted by identifier;
    /// the Grok Voice session stays unavailable on desktop hosts.
    public static let liveModels: [ModelCatalog.Option] = ModelCatalog.liveTranscription.filter {
        guard let route = LiveTranscriptionRouting.route(for: $0.id) else { return false }
        switch route.provider {
        case .deepgram, .assemblyai, .openai, .speechmatics, .soniox, .elevenlabs, .mistral, .gladia, .cartesia:
            return true
        case .xai: return route.modelID == XAISpeechToText.liveCatalogID
        default: return false
        }
    }

    /// A host can forward hints only for implemented routes whose canonical
    /// protocol capability accepts them. New routes inherit this projection.
    public static var languageHintModelIDs: Set<String> {
        Set(liveModels.filter { ModelCatalog.liveCapabilities(for: $0.id).supportsLanguageHint }.map(\.id))
    }

    /// Hosts supply native I/O; provider choice and protocol behaviour stay
    /// shared so adding a route does not require another platform-owned list.
    ///
    /// `language` is the Speak selection as stored (`en_GB`, `Automatic`, nil);
    /// a route that takes a language hint maps it to its own code and omits
    /// it when the service cannot serve it, so a host never sends a raw locale.
    ///
    /// One case per implemented route is the point of this switch: the
    /// route-to-client mapping stays auditable in one place, so its length and
    /// branch count grow with the provider list rather than with any logic.
    public static func makeClient( // swiftlint:disable:this cyclomatic_complexity function_body_length
        model: String, apiKey: String, language: String? = nil,
        makeConnection: @escaping @Sendable (URLRequest) -> any StreamingWebSocketConnection
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        guard let route = route(forID: model) else { return nil }
        let identifier = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = ModelCatalog.liveCapabilities(for: identifier).supportsLanguageHint
            ? TranscriptionLanguageCatalog.providerLanguage(for: language ?? "") : nil
        switch route.provider {
        case .openai:
            return OpenAIRealtimeLiveClient(
                apiKey: apiKey, model: route.apiModelName, language: hint?.localeLanguageCode,
                sampleRate: route.sampleRate,
                makeConnection: makeConnection
            )
        case .deepgram:
            return DeepgramLiveClient(
                apiKey: apiKey, model: route.apiModelName, language: hint, sampleRate: route.sampleRate,
                makeConnection: makeConnection
            )
        case .assemblyai:
            return AssemblyAILiveClient(
                apiKey: apiKey, speechModel: route.apiModelName, sampleRate: route.sampleRate,
                makeConnection: makeConnection
            )
        case .xai:
            // `route(forID:)` admits only the dedicated speech-to-text stream.
            return XAISpeechToTextLiveClient(
                apiKey: apiKey, language: hint, sampleRate: route.sampleRate, makeConnection: makeConnection
            )
        case .speechmatics:
            return SpeechmaticsLiveClient(
                apiKey: apiKey, model: route.apiModelName, language: hint, sampleRate: route.sampleRate,
                makeConnection: makeConnection
            )
        case .elevenlabs:
            return ElevenLabsLiveClient(
                apiKey: apiKey, modelID: route.apiModelName, language: hint,
                sampleRate: route.sampleRate, makeConnection: makeConnection
            )
        case .soniox:
            return SonioxLiveClient(
                apiKey: apiKey, model: route.apiModelName, language: hint, sampleRate: route.sampleRate,
                makeConnection: makeConnection
            )
        case .mistral:
            // Voxtral detects the spoken language itself and its session has
            // no language field, so a saved selection is never sent.
            return MistralVoxtralLiveClient(
                apiKey: apiKey, model: route.apiModelName, sampleRate: route.sampleRate, makeConnection: makeConnection
            )
        case .gladia:
            // The session request is plain HTTPS; only the single-use socket
            // it returns uses the host's native WebSocket transport. The
            // route's canonical capability accepts no language hint yet, so
            // `hint` is nil here and Gladia detects the language itself.
            return GladiaLiveClient(
                apiKey: apiKey, model: route.apiModelName, language: hint, sampleRate: route.sampleRate,
                initiateSession: GladiaLiveClient.sessionInitiator(session: .shared), makeConnection: makeConnection
            )
        case .cartesia:
            // Ink-2's canonical capability takes no language hint, so none is sent.
            return CartesiaLiveClient(
                apiKey: apiKey, model: route.apiModelName, sampleRate: route.sampleRate, makeConnection: makeConnection
            )
        default: return nil
        }
    }

    public static func route(forID modelID: String) -> LiveTranscriptionRoute? {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard liveModels.contains(where: { $0.id == identifier }) else { return nil }
        return LiveTranscriptionRouting.route(for: identifier)
    }

    /// Native desktop capture batching, independent of the driver's packet period.
    /// Deepgram's Apple controller forwards roughly 20 ms input packets directly;
    /// a 20 ms Windows frame avoids adding a 100 ms application batch. Other routes
    /// retain 100 ms, including AssemblyAI's required 50–1000 ms audio messages.
    /// Batch/unknown routes keep the existing 100 ms default. Apple capture is unchanged.
    public static func captureFrameMilliseconds(forID modelID: String) -> Int {
        route(forID: modelID)?.provider == .deepgram ? 20 : 100
    }

    public static func provider(forID modelID: String) -> TranscriptionProviderMetadata? {
        guard let route = route(forID: modelID), let credentialID = route.apiKeyIdentifier else { return nil }
        return TranscriptionProviderMetadata(
            id: route.provider.rawValue,
            displayName: route.provider.displayName,
            website: route.provider.apiKeyURL?.absoluteString ?? "",
            apiKeyIdentifier: credentialID
        )
    }
}
