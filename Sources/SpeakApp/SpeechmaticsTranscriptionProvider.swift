import Foundation
import SpeakCore

// MARK: - Errors

enum SpeechmaticsLiveError: LocalizedError {
  case batchNotSupported

  var errorDescription: String? {
    switch self {
    case .batchNotSupported:
      "Speechmatics is currently only available for live streaming in Speak."
    }
  }
}

// MARK: - Provider

struct SpeechmaticsTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "speechmatics",
    displayName: "Speechmatics",
    systemImage: "waveform.and.magnifyingglass",
    tintColor: "cyan",
    website: "https://www.speechmatics.com"
  )

  private let validationURL = URL(string: "https://eu1.asr.api.speechmatics.com/v2/jobs")!
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    guard SpeechmaticsBatchClient.catalogIDs.contains(
      model.trimmingCharacters(in: .whitespacesAndNewlines)
    ) else {
      throw SpeechmaticsLiveError.batchNotSupported
    }
    return try await SpeechmaticsBatchClient(session: session).transcribeFile(
      at: url, apiKey: apiKey, model: model, language: language
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await GETProbeAPIKeyValidator(
      url: validationURL,
      headers: { ["Authorization": "Bearer \($0)"] },
      serviceName: "Speechmatics",
      session: session,
      rejectionStatusCodes: [401, 403]
    ).validate(key)
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id)
      + ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }
}
