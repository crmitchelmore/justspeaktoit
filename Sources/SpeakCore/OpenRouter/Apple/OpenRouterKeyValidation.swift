import Foundation
import os.log

/// Checks an OpenRouter key against the auth endpoint, then the models
/// endpoint, and records a redacted debug snapshot of each attempt. The key
/// is only ever placed in the `Authorization` header and is never logged.
struct OpenRouterKeyValidation: Sendable {
    let session: URLSession
    let branding: OpenRouterBranding
    let baseURL: URL
    private let logger = SpeakLogger.logger(category: "OpenRouter")

    init(session: URLSession, branding: OpenRouterBranding, baseURL: URL = OpenRouterService.baseURL) {
        self.session = session
        self.branding = branding
        self.baseURL = baseURL
    }

    private struct ValidationAttemptResult {
        let success: Bool
        let debug: APIKeyValidationDebugSnapshot
        let message: String
    }

    private struct ValidationAttemptError: Error {
        let debug: APIKeyValidationDebugSnapshot
        let message: String
    }

    private enum ValidationAttempt {
        case authEndpoint
        case modelsEndpoint

        var path: String {
            switch self {
            case .authEndpoint: return "auth/validate"
            case .modelsEndpoint: return "models"
            }
        }

        var successMessage: String {
            switch self {
            case .authEndpoint: return "OpenRouter API key validated via auth endpoint"
            case .modelsEndpoint: return "OpenRouter API key validated via models endpoint"
            }
        }

        var unauthorizedMessage: String {
            switch self {
            case .authEndpoint: return "Unauthorized response from auth endpoint"
            case .modelsEndpoint: return "Unauthorized response from models endpoint"
            }
        }

        var logLabel: String {
            switch self {
            case .authEndpoint: return "API key auth validation failed"
            case .modelsEndpoint: return "API key validation via chat failed"
            }
        }
    }

    func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(
                message: "API key is empty",
                debug: debugSnapshot(url: "", method: "", errorDescription: "API key is empty")
            )
        }

        var lastFailure: (message: String, debug: APIKeyValidationDebugSnapshot?) =
            ("Validation failed", nil)

        for attempt in [ValidationAttempt.authEndpoint, .modelsEndpoint] {
            do {
                let result = try await runValidation(attempt, apiKey: trimmed)
                if result.success {
                    return .success(message: attempt.successMessage, debug: result.debug)
                }
                lastFailure = (result.message, result.debug)
            } catch let attemptError as ValidationAttemptError {
                logger.error(
                    "\(attempt.logLabel, privacy: .public): \(attemptError.message, privacy: .public)"
                )
                lastFailure = (attemptError.message, attemptError.debug)
            } catch {
                logger.error(
                    "\(attempt.logLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                let debug = debugSnapshot(
                    url: baseURL.appendingPathComponent(attempt.path).absoluteString,
                    method: "GET",
                    errorDescription: error.localizedDescription
                )
                lastFailure = (error.localizedDescription, debug)
            }
        }

        return .failure(message: lastFailure.message, debug: lastFailure.debug)
    }

    private func runValidation(_ attempt: ValidationAttempt, apiKey: String) async throws
        -> ValidationAttemptResult {
        let url = baseURL.appendingPathComponent(attempt.path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        branding.apply(to: &request)

        let headers = request.allHTTPHeaderFields ?? [:]

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                let debug = debugSnapshot(
                    url: url.absoluteString,
                    method: request.httpMethod ?? "GET",
                    requestHeaders: headers,
                    errorDescription: OpenRouterClientError.invalidResponse.localizedDescription
                )
                throw ValidationAttemptError(
                    debug: debug,
                    message: OpenRouterClientError.invalidResponse.localizedDescription
                )
            }
            return try evaluateValidationResponse(
                attempt, url: url, requestHeaders: headers, http: http, data: data
            )
        } catch let attemptError as ValidationAttemptError {
            throw attemptError
        } catch {
            let debug = debugSnapshot(
                url: url.absoluteString,
                method: request.httpMethod ?? "GET",
                requestHeaders: headers,
                errorDescription: error.localizedDescription
            )
            throw ValidationAttemptError(debug: debug, message: error.localizedDescription)
        }
    }

    private func evaluateValidationResponse(
        _ attempt: ValidationAttempt,
        url: URL,
        requestHeaders: [String: String],
        http: HTTPURLResponse,
        data: Data
    ) throws -> ValidationAttemptResult {
        let responseBody = string(from: data)
        let isSuccessStatus: Bool
        switch attempt {
        case .authEndpoint: isSuccessStatus = http.statusCode == 200
        case .modelsEndpoint: isSuccessStatus = (200..<300).contains(http.statusCode)
        }

        let debug = debugSnapshot(
            url: url.absoluteString,
            method: "GET",
            requestHeaders: requestHeaders,
            statusCode: http.statusCode,
            responseHeaders: normalizedHeaders(http.allHeaderFields),
            responseBody: responseBody,
            errorDescription: isSuccessStatus ? nil : responseBody
        )

        if isSuccessStatus {
            if attempt == .authEndpoint,
               let payload = try? JSONDecoder().decode(OpenRouterValidationResponse.self, from: data),
               let valid = payload.valid ?? payload.data?.valid {
                return ValidationAttemptResult(
                    success: valid,
                    debug: debug,
                    message: valid ? "Validated" : "Auth validation returned invalid"
                )
            }
            return ValidationAttemptResult(success: true, debug: debug, message: "Validated")
        }

        if http.statusCode == 401 {
            return ValidationAttemptResult(
                success: false,
                debug: debug,
                message: attempt.unauthorizedMessage
            )
        }

        throw ValidationAttemptError(
            debug: debug,
            message: "Unexpected status \(http.statusCode)"
        )
    }

    private func debugSnapshot(
        url: String,
        method: String,
        requestHeaders: [String: String] = [:],
        statusCode: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        errorDescription: String?
    ) -> APIKeyValidationDebugSnapshot {
        APIKeyValidationDebugSnapshot(
            url: url,
            method: method,
            requestHeaders: requestHeaders,
            requestBody: nil,
            statusCode: statusCode,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            errorDescription: errorDescription
        )
    }

    private func string(from data: Data?) -> String? {
        guard let data else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .ascii)
    }

    private func normalizedHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            guard let keyString = key as? String else { continue }
            if let valueString = value as? String {
                normalized[keyString] = valueString
            } else {
                normalized[keyString] = String(describing: value)
            }
        }
        return normalized
    }
}

// MARK: - Wire models

private struct OpenRouterValidationResponse: Decodable {
    struct ValidationData: Decodable {
        let valid: Bool?
    }

    let valid: Bool?
    let data: ValidationData?
}
