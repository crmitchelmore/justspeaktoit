import SpeakCore
import Foundation

/// Routes a finished recording to Apple Speech, a downloaded local model, a
/// dedicated transcription provider or the OpenRouter fallback, and answers
/// the batch pre-flight questions (remote access, stored credential).
@MainActor
struct BatchTranscriptionRouter {
  let settings: AppSettings
  let batchClient: BatchTranscriptionClient
  let openRouter: OpenRouterAPIClient
  let credentials: TranscriptionProviderCredentials

  func transcribeFile(
    at url: URL, onDiagnostic: ((TranscriptionDiagnosticReceipt) -> Void)?
  ) async throws -> TranscriptionResult {
    try await Self.performBatchTranscription(
      at: url, model: { self.offlineTranscriptionModel }, settings: settings, batchClient: batchClient,
      apiKey: { try await self.credentials.apiKey(for: $0) }, onDiagnostic: onDiagnostic
    )
  }

  // Keep the existing routing algorithm together; dependencies preserve its actor/evaluation order.
  // swiftlint:disable:next function_body_length function_parameter_count
  static func performBatchTranscription(
    at url: URL, model modelProvider: () -> String, settings: AppSettings,
    batchClient: any BatchTranscriptionClient,
    providerForModel: (String) async -> (any TranscriptionProvider)? = {
      await TranscriptionProviderRegistry.shared.provider(forModel: $0)
    },
    apiKey: (TranscriptionProviderMetadata) async throws -> String,
    onDiagnostic: ((TranscriptionDiagnosticReceipt) -> Void)?
  ) async throws -> TranscriptionResult {
    var stage: RequestDiagnosticContext.Stage = .admission
    do {
      let model = modelProvider()
      if AppleLocalModels.isSpeechAnalyzerModel(model) {
        if #available(macOS 26.0, *) {
          let locale = settings.resolvedPreferredLocaleIdentifier
          let engine = AppleSpeechAnalyzerEngine(modelID: model)
          stage = .request
          onDiagnostic?(.handoff(TranscriptionDiagnostics.handoff(model: model, language: locale, mode: .local)))
          return try await AppleSpeechAnalyzerTranscriber.transcribeFile(
            at: url,
            localeIdentifier: locale,
            engine: engine
          )
        }
        throw AppleLocalModelError.speechTranscriberUnavailable
      }
      if ModelRouting.family(for: model).isDownloadedLocal {
        let manager = LocalModelManager.shared
        let language = settings.preferredModelLanguage
        stage = .request
        onDiagnostic?(.handoff(TranscriptionDiagnostics.handoff(model: model, language: language, mode: .local)))
        return try await manager.transcribeFile(
          at: url,
          modelID: model,
          language: language
        )
      }

      // Check if this model uses a dedicated transcription provider
      if let provider = await providerForModel(model) {
        let metadata = provider.metadata
        let apiKey = try await apiKey(metadata)
        let language = settings.preferredModelLanguage
        stage = .request
        onDiagnostic?(.handoff(TranscriptionDiagnostics.handoff(
          model: model, language: language, mode: .batch, providerID: metadata.id
        )))
        return try await provider.transcribeFile(
          at: url,
          apiKey: apiKey,
          model: model,
          language: language
        )
      }

      // Fallback to OpenRouter for legacy models
      let language = settings.preferredModelLanguage
      stage = .request
      // The injected client may route internally. Never infer its provider from this model.
      onDiagnostic?(.handoff(TranscriptionDiagnostics.handoff(model: model, language: language, mode: .batch)))
      return try await batchClient.transcribeFile(
        at: url,
        model: model,
        language: language
      )
    } catch {
      onDiagnostic?(.failure(TranscriptionDiagnostics.failure(error, stage: stage)))
      throw error
    }
  }

  func batchTranscriptionUsesRemoteService() async -> Bool {
    let model = offlineTranscriptionModel
    if ModelRouting.family(for: model) == .appleSpeech {
      return false
    }
    if ModelRouting.family(for: model).isDownloadedLocal {
      return false
    }
    let registry = TranscriptionProviderRegistry.shared

    // Check if provider requires API key
    if await registry.requiresAPIKey(for: model) {
      return true
    }

    // Fallback to OpenRouter check
    return await openRouter.requiresRemoteAccess(for: model)
  }

  func hasValidBatchAPIKey() async -> Bool {
    guard await batchTranscriptionUsesRemoteService() else { return true }

    let model = offlineTranscriptionModel
    let registry = TranscriptionProviderRegistry.shared

    // Check if provider has API key
    if let provider = await registry.provider(forModel: model) {
      return await credentials.hasAPIKey(for: provider.metadata)
    }

    // Fallback to OpenRouter
    return await openRouter.hasStoredAPIKey()
  }

  var offlineTranscriptionModel: String {
    if settings.transcriptionMode == .localModel {
      return settings.localTranscriptionModel
    }
    let saved = settings.batchTranscriptionModel
    return ModelRetirements.successor(for: saved, mode: .batch) ?? saved
  }
}

struct RemoteAudioTranscriber: BatchTranscriptionClient {
  /// Held as the protocol so paid access can wrap the OpenRouter client
  /// without this type knowing which one it has.
  let client: any BatchTranscriptionClient

  func transcribeFile(at url: URL, model: String, language: String?) async throws -> TranscriptionResult {
    try await client.transcribeFile(at: url, model: model, language: language)
  }
}
