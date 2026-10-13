import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

extension DesktopLiveTranscription {
    /// Native transports stay injected, including when provider options change.
    public static func makeClient(
        model: String, apiKey: String, language: String?, azureEndpoint: String,
        options: LiveClientOptions,
        makeConnection: @escaping @Sendable (URLRequest) -> any StreamingWebSocketConnection
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        guard let route = route(forID: model) else { return nil }
        switch route.provider {
        case .assemblyai:
            return AssemblyAILiveClient(
                apiKey: apiKey, speechModel: route.apiModelName, sampleRate: route.sampleRate,
                keyterms: options.assemblyAIKeyterms,
                postStopFinalizeBudget: options.postStopFinalizeBudget,
                stopGracePeriod: options.stopGracePeriod, makeConnection: makeConnection
            )
        case .cartesia:
            return CartesiaLiveClient(
                apiKey: apiKey, model: route.apiModelName, sampleRate: route.sampleRate,
                postStopFinalizeBudget: options.postStopFinalizeBudget,
                stopGracePeriod: options.stopGracePeriod, makeConnection: makeConnection
            )
        case .xai:
            guard route.modelID == XAISpeechToText.liveCatalogID else { return nil }
            return XAISpeechToTextLiveClient(
                apiKey: apiKey, language: TranscriptionLanguageCatalog.providerLanguage(for: language ?? ""),
                keywords: options.keywords, sampleRate: route.sampleRate, makeConnection: makeConnection
            )
        default:
            return makeClient(
                model: model, apiKey: apiKey, language: language, azureEndpoint: azureEndpoint,
                makeConnection: makeConnection
            )
        }
    }
}
