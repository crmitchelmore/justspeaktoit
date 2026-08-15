import Foundation

// MARK: - Provider Protocol

public protocol TranscriptionProvider: Sendable {
    var metadata: TranscriptionProviderMetadata { get }

    func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult
    func requiresAPIKey(for model: String) -> Bool
    func supportedModels() -> [ModelCatalog.Option]
}

// MARK: - Provider Metadata

public struct TranscriptionProviderMetadata: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let apiKeyIdentifier: String
    public let apiKeyLabel: String
    public let systemImage: String
    public let tintColor: String // Color name for UI
    public let website: String

    public init(
        id: String,
        displayName: String,
        systemImage: String = "network",
        tintColor: String = "blue",
        website: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.apiKeyIdentifier = "\(id).apiKey"
        self.apiKeyLabel = "\(displayName) API Key"
        self.systemImage = systemImage
        self.tintColor = tintColor
        self.website = website
    }

    public var apiKeyURL: URL? {
        guard !website.isEmpty else { return nil }
        return URL(string: website)
    }
}

// MARK: - Provider Error

/// The failure cases that every transcription provider shares.
///
/// The descriptions are user-visible: they reach the HUD, the history entry and
/// the diagnostics report. Keep the established wording. `httpError` keeps the
/// status code and the response body, because that context is what makes a
/// provider failure diagnosable.
public enum TranscriptionProviderError: LocalizedError {
    case apiKeyMissing
    case invalidResponse
    case httpError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "API key is required but not provided."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpError(let code, let body):
            return "Server responded with status \(code): \(body)"
        }
    }
}

// NOTE: TranscriptionProviderRegistry actor stays in SpeakApp since it references
// concrete provider implementations (OpenAI, Rev.ai, Deepgram) which are platform-specific.
