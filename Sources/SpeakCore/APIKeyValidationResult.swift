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
        // Automatically redact sensitive headers to prevent exposure in debug UI
        self.requestHeaders = SensitiveHeaderRedactor.redactSensitiveHeaders(requestHeaders)
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = SensitiveHeaderRedactor.redactSensitiveHeaders(responseHeaders)
        self.responseBody = responseBody
        self.errorDescription = errorDescription
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
