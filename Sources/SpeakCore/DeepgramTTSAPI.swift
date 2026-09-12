import Foundation

/// Errors surfaced by the shared Deepgram Aura speech-synthesis transport.
///
/// Each platform client maps these onto its own error type so existing
/// user-facing behaviour is preserved.
public enum DeepgramTTSAPIError: Error, Sendable, Equatable {
    case invalidURL
    case invalidResponse
    /// HTTP 401/403 — the key is missing, wrong or revoked.
    case unauthorized(statusCode: Int, message: String)
    /// Any other non-2xx response.
    case httpError(statusCode: Int, message: String)
}

/// Shared Deepgram Aura text-to-speech transport used by both the macOS and
/// iOS clients.
///
/// Owns request construction, authentication headers and response
/// classification only — audio playback, file handling and cost accounting
/// stay with each platform caller. The API key travels solely in the
/// `Authorization` header and is never logged or embedded in errors.
public struct DeepgramTTSAPI: Sendable {
    /// Synthesis endpoint; callers append `model` and format query items.
    public static let speakEndpoint = URL(string: "https://api.deepgram.com/v1/speak")!
    static let fluxSpeakEndpoint = URL(string: "https://api.deepgram.com/v2/speak")!
    /// Cheap authenticated endpoint used to validate API keys.
    public static let projectsEndpoint = URL(string: "https://api.deepgram.com/v1/projects")!
    /// Deepgram Aura pricing: $0.0135 per 1000 characters.
    public static let costPerThousandCharacters = Decimal(string: "0.0135")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// POSTs `text` to `/v2/speak` for Flux voices, or `/v1/speak` for Aura, and returns the synthesized audio bytes.
    ///
    /// - Parameters:
    ///   - text: Text to synthesize.
    ///   - apiKey: Deepgram API key, sent as `Token` authorization.
    ///   - queryItems: The `model` parameter plus any encoding/container/
    ///     sample-rate parameters the caller needs.
    public func synthesize(
        text: String,
        apiKey: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let model = queryItems.first { $0.name == "model" }?.value ?? ""
        let endpoint = model.hasPrefix("flux-") ? Self.fluxSpeakEndpoint : Self.speakEndpoint
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw DeepgramTTSAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramTTSAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw DeepgramTTSAPIError.unauthorized(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepgramTTSAPIError.httpError(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        return data
    }

    /// Validates a Deepgram API key against the `/v1/projects` endpoint.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        var request = URLRequest(url: Self.projectsEndpoint)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(message: "Invalid response")
            }

            if httpResponse.statusCode == 200 {
                return .success(message: "API key is valid")
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failure(message: "Invalid API key")
            } else {
                return .failure(message: "HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
