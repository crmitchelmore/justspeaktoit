import Foundation
import SpeakCore

extension ModulateTranscriptionFeatures {
  init(defaults: UserDefaults) {
    let fallback = Self()
    self.init(
      speakerDiarization: defaults.object(forKey: AppSettings.DefaultsKey.modulateSpeakerDiarization.rawValue) as? Bool
        ?? fallback.speakerDiarization,
      emotionSignal: defaults.object(forKey: AppSettings.DefaultsKey.modulateEmotionSignal.rawValue) as? Bool
        ?? fallback.emotionSignal,
      accentSignal: defaults.object(forKey: AppSettings.DefaultsKey.modulateAccentSignal.rawValue) as? Bool
        ?? fallback.accentSignal,
      piiPhiTagging: defaults.object(forKey: AppSettings.DefaultsKey.modulatePIIPhiTagging.rawValue) as? Bool
        ?? fallback.piiPhiTagging
    )
  }
}

struct ModulateTranscriptionProvider: TranscriptionProvider {
  private let session: URLSession
  private let defaultsSuiteName: String?
  private let multipartStaging: MultipartUploadStaging
  var metadata: TranscriptionProviderMetadata { client.metadata }

  init(
    session: URLSession = .shared, defaults: UserDefaults = .standard,
    multipartStaging: MultipartUploadStaging = .shared
  ) {
    self.session = session
    self.defaultsSuiteName = Self.defaultsSuiteName(for: defaults)
    self.multipartStaging = multipartStaging
  }

  private var client: ModulateBatchClient {
    ModulateBatchClient(
      session: session, features: ModulateTranscriptionFeatures(defaults: currentDefaults()),
      multipartStaging: multipartStaging.sharedStore
    )
  }

  func transcribeFile(
    at url: URL, apiKey: String, model: String, language: String?
  ) async throws -> TranscriptionResult {
    try await client.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult { await client.validateAPIKey(key) }
  func requiresAPIKey(for model: String) -> Bool { client.requiresAPIKey(for: model) }
  func supportedModels() -> [ModelCatalog.Option] { client.supportedModels() }
  func makeValidationRequest(apiKey: String) -> URLRequest { client.makeValidationRequest(apiKey: apiKey) }

  private func currentDefaults() -> UserDefaults {
    guard let defaultsSuiteName, let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
      return .standard
    }
    return defaults
  }

  private static func defaultsSuiteName(for defaults: UserDefaults) -> String? {
    let standardDomain = Bundle.main.bundleIdentifier ?? "com.github.speakapp"
    let argumentDomain = "NSArgumentDomain"
    let registrationDomain = "NSRegistrationDomain"
    return defaults
      .volatileDomainNames
      .first(where: { name in name != argumentDomain && name != registrationDomain && name != standardDomain })
  }

}
