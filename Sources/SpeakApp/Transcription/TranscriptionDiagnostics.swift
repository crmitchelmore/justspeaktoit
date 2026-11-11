import SpeakCore
import Foundation

/// What a batch or live request handed to its provider, or how it failed,
/// reported to the session that owns it.
enum TranscriptionDiagnosticReceipt {
  case handoff(RequestDiagnosticContext)
  case failure(RequestDiagnosticContext.Failure)
}

/// Projects typed transcription errors into privacy-safe diagnostic failures.
enum TranscriptionDiagnostics {
  static func handoff(
    model: String, language: String?, mode: RequestDiagnosticContext.Mode, providerID: String? = nil
  ) -> RequestDiagnosticContext {
    RequestDiagnosticContext(
      provenance: .observedHandoff, model: .project(model), observedProvider: providerID.map { .project($0) },
      mode: mode, language: .project(language), options: .init(streamingEnabled: false)
    )
  }

  static func failure(_ error: Error, stage: RequestDiagnosticContext.Stage) -> RequestDiagnosticContext.Failure {
    if error is CancellationError { return .init(stage: stage, code: .cancelled, domain: .application) }
    if let transport = error as? URLError {
      let codes: [URLError.Code: RequestDiagnosticContext.FailureCode] = [.timedOut: .timeout, .cancelled: .cancelled]
      return .init(stage: stage, code: codes[transport.code] ?? .transport, domain: .transport)
    }
    if let provider = error as? TranscriptionProviderError {
      return Self.providerFailure(provider, stage: stage)
    }
    if let client = error as? OpenRouterClientError {
      switch client {
      case .apiKeyMissing: return .init(stage: stage, code: .authentication, domain: .application)
      case .invalidResponse: return .init(stage: stage, code: .unknown, domain: .provider)
      case .httpStatus(let status, _): return Self.httpFailure(status, stage: stage)
      case .audioFileTooLarge: return .init(stage: stage, code: .invalidInput, domain: .application)
      }
    }
    return .init(stage: stage, code: .unknown, domain: .unknown)
  }

  private static func providerFailure(
    _ error: TranscriptionProviderError, stage: RequestDiagnosticContext.Stage
  ) -> RequestDiagnosticContext.Failure {
    switch error {
    case .apiKeyMissing: return .init(stage: stage, code: .authentication, domain: .application)
    case .invalidResponse: return .init(stage: stage, code: .unknown, domain: .provider)
    case .httpError(let status, _): return Self.httpFailure(status, stage: stage)
    }
  }

  private static func httpFailure(_ status: Int, stage: RequestDiagnosticContext.Stage)
    -> RequestDiagnosticContext.Failure {
    .init(stage: stage, code: status == 401 || status == 403 ? .authentication : .unknown,
          domain: .provider, httpStatus: status)
  }
}
