import SpeakCore
import Foundation

/// Resolves which live model the current mode records with, whether that route
/// captures through `LiveInputEngines.shared`, and whether its key is missing.
@MainActor
struct LiveTranscriptionRouter {
  let settings: AppSettings
  let liveController: SwitchingLiveTranscriber
  let credentials: TranscriptionProviderCredentials

  /// Whether the live route for the current mode captures through
  /// `LiveInputEngines.shared`; record-start prepares an engine only then.
  var usesLiveInputEngine: Bool {
    guard settings.transcriptionMode == .liveNative
      || (settings.transcriptionMode == .localModel && settings.localTranscriptionMode == .streaming)
    else { return false }
    guard let model = try? modelForCurrentMode() else { return false }
    return liveController.usesLiveInputEngine(for: model)
  }

  /// Read-only projection of the same per-app override applied at session start.
  func usesLiveInputEngine(profiles: [DictationProfile], frontmostBundleID: String?) -> Bool {
    let profile = ProfileResolver(profiles: profiles).profile(forBundleID: frontmostBundleID)
    guard let override = profile?.resolvedTranscriptionOverride else { return usesLiveInputEngine }
    guard override.routing == .remoteStreaming else { return false }
    return liveController.usesLiveInputEngine(for: override.modelID)
  }

  func modelForCurrentMode() throws -> String {
    try Self.resolvedLiveTranscriptionModel(
      transcriptionMode: settings.transcriptionMode,
      localTranscriptionMode: settings.localTranscriptionMode,
      localStreamingModelSource: settings.localStreamingModelSource,
      liveTranscriptionModel: settings.liveTranscriptionModel,
      availableStreamingSourceIDs: availableLocalStreamingSourceIDs()
    )
  }

  private func availableLocalStreamingSourceIDs() -> Set<String> {
    var availableStreamingSourceIDs = Set(
      LocalModelManager.shared.availableModels
        .filter(\.supportsLiveStreaming)
        .filter { LocalModelManager.shared.isInstalled($0.id) }
        .map(WhisperKitStreamingModel.id(for:))
    )
    if FluidAudioModelManager.supportsCurrentHardware {
      availableStreamingSourceIDs.insert(FluidAudioParakeetModel.id)
    }
    #if !APP_STORE
    availableStreamingSourceIDs.formUnion(LocalModelManager.recommendedStreamingModelSources.map(\.id))
    availableStreamingSourceIDs.formUnion(LocalModelManager.shared.streamingModelSources.map(\.id))
    #endif
    return availableStreamingSourceIDs
  }

  nonisolated static func resolvedLiveTranscriptionModel(
    transcriptionMode: AppSettings.TranscriptionMode,
    localTranscriptionMode: AppSettings.LocalTranscriptionMode,
    localStreamingModelSource: String,
    liveTranscriptionModel: String,
    availableStreamingSourceIDs: @autoclosure () -> Set<String>
  ) throws -> String {
    guard transcriptionMode == .localModel, localTranscriptionMode == .streaming else {
      // A running app crossing a shutdown day follows the automatic successor.
      return ModelRetirements.successor(for: liveTranscriptionModel, mode: .live) ?? liveTranscriptionModel
    }

    guard localStreamingModelSource.hasPrefix("local/streaming/"),
      availableStreamingSourceIDs().contains(localStreamingModelSource)
    else {
      throw TranscriptionManagerError.invalidLocalStreamingSource(localStreamingModelSource)
    }

    return localStreamingModelSource
  }

  /// Returns the metadata for the live-transcription provider whose API key is
  /// missing — `nil` if the current live model needs no key, or its key is set.
  /// Used for the "API key required" pre-flight alert before a live recording.
  func missingAPIKeyProvider() async -> TranscriptionProviderMetadata? {
    let model = settings.liveTranscriptionModel
    let registry = TranscriptionProviderRegistry.shared
    guard await registry.requiresAPIKey(for: model) else { return nil }
    guard let provider = await registry.provider(forModel: model) else { return nil }
    if await credentials.hasAPIKey(for: provider.metadata) { return nil }
    return provider.metadata
  }
}
