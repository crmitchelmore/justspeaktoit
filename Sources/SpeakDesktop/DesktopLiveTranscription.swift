import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Live providers implemented by the shared desktop session. Hosts must also
/// qualify their native transport before exposing this projection in the UI.
/// Models, routing and credential metadata remain owned by SpeakCore.
public enum DesktopLiveTranscription {
    public static let liveModels: [ModelCatalog.Option] = ModelCatalog.liveTranscription.filter {
        guard let provider = LiveTranscriptionRouting.route(for: $0.id)?.provider else { return false }
        return provider == .deepgram || provider == .assemblyai
    }

    /// Hosts supply native I/O; provider choice and protocol behaviour stay
    /// shared so adding a route does not require another platform-owned list.
    public static func makeClient(
        model: String, apiKey: String,
        makeConnection: @escaping @Sendable (URLRequest) -> any StreamingWebSocketConnection
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        guard let route = route(forID: model) else { return nil }
        switch route.provider {
        case .deepgram:
            return DeepgramLiveClient(
                apiKey: apiKey, model: route.apiModelName, sampleRate: route.sampleRate,
                makeConnection: makeConnection
            )
        case .assemblyai:
            return AssemblyAILiveClient(
                apiKey: apiKey, speechModel: route.apiModelName, sampleRate: route.sampleRate,
                makeConnection: makeConnection
            )
        default: return nil
        }
    }

    public static func route(forID modelID: String) -> LiveTranscriptionRoute? {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard liveModels.contains(where: { $0.id == identifier }) else { return nil }
        return LiveTranscriptionRouting.route(for: identifier)
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
