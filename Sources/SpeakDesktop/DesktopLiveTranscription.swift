import Foundation
import SpeakCore

/// Live providers implemented by the shared desktop session. Hosts must also
/// qualify their native transport before exposing this projection in the UI.
/// Models, routing and credential metadata remain owned by SpeakCore.
public enum DesktopLiveTranscription {
    public static let liveModels: [ModelCatalog.Option] = ModelCatalog.liveTranscription.filter {
        LiveTranscriptionRouting.route(for: $0.id)?.provider == .deepgram
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
