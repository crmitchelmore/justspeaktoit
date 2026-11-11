import Foundation
import SpeakCore

/// How a desktop host can transcribe a saved recording again. A retry always
/// uses the model the recording was made with, never the current picker or a
/// profile, so the route depends only on that saved identifier.
public enum DesktopHistoryRetry: Equatable, Sendable {
    /// A remote batch provider transcribes the saved audio.
    case remote
    /// A downloaded on-device model. Whether this host can run it now (its
    /// download and speech runtime) is the host's readiness check.
    case onDevice
    /// A live-only model: its saved audio can be imported with a batch model.
    case liveOnly
    /// A model this version no longer offers.
    case unavailable

    public static func route(for modelID: String) -> DesktopHistoryRetry {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if DesktopTranscription.provider(for: identifier) != nil { return .remote }
        // Downloaded models use `local/...` identifiers on every platform. They
        // have no remote provider, so a provider test alone mistakes them for live.
        if identifier.lowercased().hasPrefix("local/") { return .onDevice }
        return isLive(identifier) ? .liveOnly : .unavailable
    }

    /// A catalogued live model, or a retired one the catalogue still migrates.
    private static func isLive(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let migrated = ModelCatalog.normalizedLiveTranscriptionModel(identifier)
        return ModelCatalog.liveTranscription.contains { $0.id == identifier || $0.id == migrated }
    }
}
