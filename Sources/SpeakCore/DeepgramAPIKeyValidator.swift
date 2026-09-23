import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - API Key Validation

public struct DeepgramAPIKeyValidator {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Validates a Deepgram API key by making a test request.
    public func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        let url = URL(string: "https://api.deepgram.com/v1/projects")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Received a non-HTTP response")
            }

            if (200..<300).contains(http.statusCode) {
                return .success(message: "Deepgram API key validated")
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            return .failure(message: "HTTP \(http.statusCode): \(body)")
        } catch {
            return .failure(message: "Validation failed: \(error.localizedDescription)")
        }
    }
}
