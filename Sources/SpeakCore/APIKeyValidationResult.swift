import Foundation

public struct APIKeyValidationDebugSnapshot: Sendable, Equatable {
    public let url: String
    public let method: String
    public let requestHeaders: [String: String]
    public let requestBody: String?
    public let statusCode: Int?
    public let responseHeaders: [String: String]
    public let responseBody: String?
    public let errorDescription: String?

    /// Creates a debug snapshot with automatic redaction of sensitive headers
    /// - Parameters:
    ///   - url: Request URL
    ///   - method: HTTP method
    ///   - requestHeaders: Request headers (will be redacted)
    ///   - requestBody: Request body
    ///   - statusCode: HTTP status code
    ///   - responseHeaders: Response headers (will be redacted)
    ///   - responseBody: Response body
    ///   - errorDescription: Error description if any
    public init(
        url: String,
        method: String,
        requestHeaders: [String: String],
        requestBody: String?,
        statusCode: Int?,
        responseHeaders: [String: String],
        responseBody: String?,
        errorDescription: String?
    ) {
        self.url = url
        self.method = method
        // Snapshots are stored and rendered in the debug UI, so sensitive header
        // values are replaced outright — no prefix/suffix of the credential is
        // retained. Callers therefore never need to pre-blank the auth header.
        self.requestHeaders = SensitiveHeaderRedactor.fullyRedactSensitiveHeaders(requestHeaders)
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = SensitiveHeaderRedactor.fullyRedactSensitiveHeaders(responseHeaders)
        self.responseBody = responseBody
        self.errorDescription = errorDescription
    }
}

extension APIKeyValidationDebugSnapshot {
    /// Captures the request/response pair of an API-key validation probe.
    ///
    /// Every provider used to carry its own verbatim copy of this mapping; they now
    /// share this one. Sensitive request and response headers are redacted by the
    /// initialiser this calls.
    public static func capture(
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

public struct APIKeyValidationResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case success(message: String)
        case failure(message: String)
    }

    public let outcome: Outcome
    public let debug: APIKeyValidationDebugSnapshot?

    public init(outcome: Outcome, debug: APIKeyValidationDebugSnapshot?) {
        self.outcome = outcome
        self.debug = debug
    }

    public static func success(message: String, debug: APIKeyValidationDebugSnapshot? = nil) -> Self {
        APIKeyValidationResult(outcome: .success(message: message), debug: debug)
    }

    public static func failure(message: String, debug: APIKeyValidationDebugSnapshot? = nil) -> Self {
        APIKeyValidationResult(outcome: .failure(message: message), debug: debug)
    }

    public func updatingOutcome(_ outcome: Outcome) -> Self {
        APIKeyValidationResult(outcome: outcome, debug: debug)
    }
}

/// Validates an API key by issuing an authenticated `GET` probe against a cheap
/// endpoint: any 2xx response means the key works.
///
/// Most providers validate exactly this way and only differ in the probe URL, the
/// header carrying the credential, and the service name used in the message, so
/// they share this type instead of each re-implementing
/// trim → probe → snapshot → classify.
public struct GETProbeAPIKeyValidator {
    private let url: URL
    private let headers: (String) -> [String: String]
    private let serviceName: String
    private let session: URLSession
    private let rejectionStatusCodes: Set<Int>

    /// - Parameters:
    ///   - url: Probe endpoint, including any query items.
    ///   - headers: Builds the probe's headers from the trimmed key.
    ///   - serviceName: Name used in the success and rejection messages.
    ///   - session: Session used for the probe.
    ///   - rejectionStatusCodes: Status codes reported as an explicit rejection
    ///     ("<service> rejected the key (HTTP n)") rather than the generic HTTP failure.
    public init(
        url: URL,
        headers: @escaping (String) -> [String: String],
        serviceName: String,
        session: URLSession = .shared,
        rejectionStatusCodes: Set<Int> = []
    ) {
        self.url = url
        self.headers = headers
        self.serviceName = serviceName
        self.session = session
        self.rejectionStatusCodes = rejectionStatusCodes
    }

    public func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        var request = URLRequest(url: self.url)
        request.httpMethod = "GET"
        for (field, value) in self.headers(trimmed) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Received a non-HTTP response", debug: .capture(request: request))
            }

            let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
            if (200..<300).contains(http.statusCode) {
                return .success(message: "\(self.serviceName) API key validated", debug: debug)
            }
            if self.rejectionStatusCodes.contains(http.statusCode) {
                return .failure(
                    message: "\(self.serviceName) rejected the key (HTTP \(http.statusCode))",
                    debug: debug
                )
            }
            return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
        } catch {
            return .failure(
                message: "Validation failed: \(error.localizedDescription)",
                debug: .capture(request: request, error: error)
            )
        }
    }
}
