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
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
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
