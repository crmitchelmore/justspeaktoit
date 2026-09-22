import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - API Key Validation

public struct ElevenLabsSTTAPIKeyValidator {
    /// Batch Scribe model used for the access probe. ElevenLabs removed
    /// `scribe_v1` on 2026-07-09, so probing with it now fails for every key.
    public static let defaultProbeModelID = "scribe_v2"

    private let session: URLSession
    private let modelID: String
    private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!

    public init(
        session: URLSession = .shared,
        modelID: String = ElevenLabsSTTAPIKeyValidator.defaultProbeModelID
    ) {
        self.session = session
        self.modelID = modelID
    }

    /// Validates that an ElevenLabs API key is valid and has Scribe speech-to-text access.
    public func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        let request = makeUserRequest(apiKey: trimmed)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "Received a non-HTTP response",
                    debug: debugSnapshot(request: request)
                )
            }

            let debug = debugSnapshot(request: request, response: http, data: data)
            guard http.statusCode != 401 else {
                return .failure(message: "Invalid API key", debug: debug)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
            }
        } catch {
            return .failure(
                message: "Validation failed: \(error.localizedDescription)",
                debug: debugSnapshot(request: request, error: error)
            )
        }

        return await validateScribeAccess(apiKey: trimmed)
    }

    private func makeUserRequest(apiKey: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("user")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func makeScribeProbeRequest(apiKey: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("speech-to-text")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            --\(boundary)\r
            Content-Disposition: form-data; name="model_id"\r
            \r
            \(modelID)\r
            --\(boundary)--\r
            """.utf8
        )
        return request
    }

    private func validateScribeAccess(apiKey: String) async -> APIKeyValidationResult {
        let request = makeScribeProbeRequest(apiKey: apiKey)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "Received a non-HTTP response from Scribe",
                    debug: debugSnapshot(request: request)
                )
            }

            let debug = debugSnapshot(request: request, response: http, data: data)
            if http.statusCode == 403 {
                return .failure(
                    message: "API key does not have Scribe (speech-to-text) access. Use a key with both "
                        + "TTS and Scribe permissions.",
                    debug: debug
                )
            }
            if http.statusCode == 401 {
                return .failure(message: "Invalid API key", debug: debug)
            }
            if isAcceptedScribeProbeStatus(http.statusCode) {
                return .success(
                    message: "ElevenLabs API key is valid for Text-to-Speech and Scribe transcription",
                    debug: debug
                )
            }

            return .failure(message: "HTTP \(http.statusCode) while probing Scribe access", debug: debug)
        } catch {
            return .failure(
                message: "Scribe validation failed: \(error.localizedDescription)",
                debug: debugSnapshot(request: request, error: error)
            )
        }
    }

    private func isAcceptedScribeProbeStatus(_ statusCode: Int) -> Bool {
        (200..<300).contains(statusCode) || statusCode == 400 || statusCode == 415 || statusCode == 422
    }

    private func debugSnapshot(
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        data: Data? = nil,
        error: Error? = nil
    ) -> APIKeyValidationDebugSnapshot {
        APIKeyValidationDebugSnapshot(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestBody: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            statusCode: response?.statusCode,
            responseHeaders: response.map { headers in
                headers.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
                    guard let key = entry.key as? String else { return }
                    partialResult[key] = String(describing: entry.value)
                }

            } ?? [:],
            responseBody: data.flatMap { String(data: $0, encoding: .utf8) },
            errorDescription: error?.localizedDescription
        )
    }
}
