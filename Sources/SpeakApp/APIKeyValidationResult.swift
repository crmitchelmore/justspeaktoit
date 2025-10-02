import Foundation

struct APIKeyValidationDebugSnapshot: Sendable, Equatable {
  let url: String
  let method: String
  let requestHeaders: [String: String]
  let requestBody: String?
  let statusCode: Int?
  let responseHeaders: [String: String]
  let responseBody: String?
  let errorDescription: String?
}

struct APIKeyValidationResult: Sendable, Equatable {
  enum Outcome: Sendable, Equatable {
    case success(message: String)
    case failure(message: String)
  }

  let outcome: Outcome
  let debug: APIKeyValidationDebugSnapshot?

  static func success(message: String, debug: APIKeyValidationDebugSnapshot? = nil) -> Self {
    APIKeyValidationResult(outcome: .success(message: message), debug: debug)
  }

  static func failure(message: String, debug: APIKeyValidationDebugSnapshot? = nil) -> Self {
    APIKeyValidationResult(outcome: .failure(message: message), debug: debug)
  }

  func updatingOutcome(_ outcome: Outcome) -> Self {
    APIKeyValidationResult(outcome: outcome, debug: debug)
  }
}
