import SpeakCore
import AppKit
@preconcurrency import AVFoundation
import Foundation
import Speech

// swiftlint:disable file_length

/// Applies the user-configured extra stop-grace period uniformly across all
/// live transcription providers. This sits on top of each provider's
/// hard-coded `LiveModelCapabilities.postStopFinalizeBudget` and lets the
/// user buy themselves a bit of extra trailing-audio finalisation time
/// (originally a Deepgram-only knob, now generalised).
func applyLiveStopGrace(_ period: TimeInterval) async {
  let grace = max(period, 0)
  guard grace > 0 else { return }
  try? await Task.sleep(for: .seconds(grace))
}

enum TranscriptionManagerError: LocalizedError, Equatable {
  case liveSessionAlreadyRunning
  case liveSessionNotRunning
  case recognizerUnavailable
  case permissionsMissing
  case microphonePermissionMissing
  case localLiveStreamingUnsupported
  case localLiveStreamingStartupTimedOut
  case invalidLocalStreamingSource(String)
  case noUsableAudioInput

  var errorDescription: String? {
    switch self {
    case .liveSessionAlreadyRunning:
      return "A live transcription session is already running."
    case .liveSessionNotRunning:
      return "No live transcription session is currently running."
    case .recognizerUnavailable:
      return "The speech recogniser could not be configured for the selected locale."
    case .permissionsMissing:
      return "Required microphone or speech recognition permissions are missing."
    case .microphonePermissionMissing:
      return "Microphone permission is missing. Grant microphone access in System Settings and try again."
    case .localLiveStreamingUnsupported:
      return "The selected downloaded model does not support Local Streaming. Choose another model or use Local Batch."
    case .localLiveStreamingStartupTimedOut:
      return "The local streaming model did not start receiving microphone audio in time. " +
        "Try reconnecting the input device."
    case .invalidLocalStreamingSource(let sourceID):
      return "Local streaming source is not available: \(sourceID). " +
        "Choose or download a local streaming model in Settings."
    case .noUsableAudioInput:
      return "The selected microphone is unavailable. Pick a different input device in Settings and try again."
    }
  }
}

/// Returns `true` when an `AVAudioEngine` input format describes a usable capture
/// device. A stale or disconnected input device reports zero channels or a zero
/// sample rate, which would otherwise surface as `kAudioHardwareBadDeviceError`
/// (`com.apple.coreaudio.avfaudio error 560227702`) when starting the engine.
func audioInputFormatIsUsable(_ format: AVAudioFormat) -> Bool {
  format.channelCount > 0 && format.sampleRate > 0
}

private let coreAudioBadDeviceErrorCode = 560_227_702
private let avfaudioErrorDomain = "com.apple.coreaudio.avfaudio"
private let staleInputDeviceRetryDelay: Duration = .milliseconds(200)

func startAudioEngineAfterInputDeviceSettles(_ audioEngine: AVAudioEngine) async throws {
  do {
    audioEngine.prepare()
    try audioEngine.start()
  } catch {
    guard audioInputStartErrorIsBadDevice(error) else {
      throw error
    }

    audioEngine.stop()
    try await Task.sleep(for: staleInputDeviceRetryDelay)

    do {
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      throw normalisedAudioInputStartError(error)
    }
  }
}

func normalisedAudioInputStartError(_ error: Error) -> Error {
  audioInputStartErrorIsBadDevice(error)
    ? TranscriptionManagerError.noUsableAudioInput
    : error
}

func audioInputStartErrorIsBadDevice(_ error: Error) -> Bool {
  let nsError = error as NSError
  if nsError.code == coreAudioBadDeviceErrorCode,
    nsError.domain == avfaudioErrorDomain || nsError.domain == NSOSStatusErrorDomain {
    return true
  }
  if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
    return audioInputStartErrorIsBadDevice(underlying)
  }
  return false
}

@MainActor
final class TranscriptionManager: ObservableObject {
  @Published private(set) var livePartialText: String = ""
  @Published private(set) var liveTextIsFinal: Bool = true
  @Published private(set) var liveTextConfidence: Double?
  @Published private(set) var isLiveTranscribing: Bool = false
  @Published private(set) var utteranceBoundaryText: String?

  private let appSettings: AppSettings
  private let liveController: SwitchingLiveTranscriber
  private let batchClient: BatchTranscriptionClient
  private let openRouter: OpenRouterAPIClient
  private let secureStorage: SecureAppStorage

  private var continuation: CheckedContinuation<TranscriptionResult, Error>?
  private var pendingError: Error?
  /// Monotonic token identifying the current stop request. The safety timeout
  /// captures the value at spawn time and only fires if it still matches, so a
  /// stale timeout from an earlier session can never resume a later session's
  /// continuation.
  private var stopGeneration = 0
  private var stopTimeoutTask: Task<Void, Never>?

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    batchClient: BatchTranscriptionClient,
    openRouter: OpenRouterAPIClient,
    secureStorage: SecureAppStorage
  ) {
    self.appSettings = appSettings
    self.liveController = SwitchingLiveTranscriber(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    self.batchClient = batchClient
    self.openRouter = openRouter
    self.secureStorage = secureStorage
    self.liveController.delegate = self
  }

  func startLiveTranscription() async throws {
    guard !isLiveTranscribing else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
    let model = try liveTranscriptionModelForCurrentMode()
    let language = appSettings.preferredModelLanguage
    print("[TranscriptionManager] startLiveTranscription - model: \(model), language: \(language ?? "automatic")")
    liveController.configure(
      language: language,
      model: model
    )
    try await liveController.start()
    livePartialText = ""
    pendingError = nil
    isLiveTranscribing = true
  }

  func stopLiveTranscription() async throws -> TranscriptionResult {
    // If there was a mid-session error, still stop the controller so audio resources
    // and preferred input-device sessions are released before surfacing the failure.
    if let error = pendingError {
      pendingError = nil
      isLiveTranscribing = false
      Task { await liveController.stop() }
      throw error
    }
    guard isLiveTranscribing else { throw TranscriptionManagerError.liveSessionNotRunning }
    stopGeneration += 1
    let generation = stopGeneration
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      Task {
        await self.liveController.stop()
      }
      // Safety timeout: if the delegate never calls back, resume with an error
      // rather than hanging forever. Guarded by the generation token so a stale
      // timeout from a previous session can't resume a later session's continuation.
      stopTimeoutTask?.cancel()
      stopTimeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard let self, !Task.isCancelled,
          self.stopGeneration == generation,
          let cont = self.continuation
        else { return }
        print("[TranscriptionManager] Safety timeout: continuation not resumed after 10s, forcing error")
        self.continuation = nil
        self.stopTimeoutTask = nil
        self.isLiveTranscribing = false
        cont.resume(throwing: TranscriptionManagerError.liveSessionNotRunning)
      }
    }
  }

  /// Cancels the pending stop safety timeout once the continuation has been
  /// resumed through a normal path (delegate callback or explicit cancel).
  private func cancelStopTimeout() {
    stopTimeoutTask?.cancel()
    stopTimeoutTask = nil
  }

  func cancelLiveTranscription() {
    cancelStopTimeout()
    continuation?.resume(throwing: TranscriptionManagerError.liveSessionNotRunning)
    continuation = nil
    Task {
      await liveController.stop()
    }
    isLiveTranscribing = false
    livePartialText = ""
  }

  /// Marks the live controller cache as stale so it re-reads credentials on next start.
  /// Call this before removing a credential from Keychain to ensure no stale session is reused.
  @MainActor
  func invalidateLiveControllerCache() {
    liveController.markControllersStale()
  }

  func transcribeFile(at url: URL) async throws -> TranscriptionResult {
    let model = offlineTranscriptionModel
    if model == AppleLocalModels.speechTranscriberModelID {
      if #available(macOS 26.0, *) {
        return try await AppleSpeechAnalyzerTranscriber.transcribeFile(
          at: url,
          localeIdentifier: appSettings.resolvedPreferredLocaleIdentifier
        )
      }
      throw AppleLocalModelError.speechTranscriberUnavailable
    }
    if ModelRouting.family(for: model).isDownloadedLocal {
      return try await LocalModelManager.shared.transcribeFile(
        at: url,
        modelID: model,
        language: appSettings.preferredModelLanguage
      )
    }

    let registry = TranscriptionProviderRegistry.shared

    // Check if this model uses a dedicated transcription provider
    if let provider = await registry.provider(forModel: model) {
      let apiKey = try await getAPIKey(for: provider.metadata)
      return try await provider.transcribeFile(
        at: url,
        apiKey: apiKey,
        model: model,
        language: appSettings.preferredModelLanguage
      )
    }

    // Fallback to OpenRouter for legacy models
    return try await batchClient.transcribeFile(
      at: url,
      model: model,
      language: appSettings.preferredModelLanguage
    )
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
      return await hasAPIKey(for: provider.metadata)
    }

    // Fallback to OpenRouter
    return await openRouter.hasStoredAPIKey()
  }

  private var offlineTranscriptionModel: String {
    if appSettings.transcriptionMode == .localModel {
      return appSettings.localTranscriptionModel
    }
    return appSettings.batchTranscriptionModel
  }

  private func liveTranscriptionModelForCurrentMode() throws -> String {
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
    return try Self.resolvedLiveTranscriptionModel(
      transcriptionMode: appSettings.transcriptionMode,
      localTranscriptionMode: appSettings.localTranscriptionMode,
      localStreamingModelSource: appSettings.localStreamingModelSource,
      liveTranscriptionModel: appSettings.liveTranscriptionModel,
      availableStreamingSourceIDs: availableStreamingSourceIDs
    )
  }

  nonisolated static func resolvedLiveTranscriptionModel(
    transcriptionMode: AppSettings.TranscriptionMode,
    localTranscriptionMode: AppSettings.LocalTranscriptionMode,
    localStreamingModelSource: String,
    liveTranscriptionModel: String,
    availableStreamingSourceIDs: Set<String>
  ) throws -> String {
    guard transcriptionMode == .localModel, localTranscriptionMode == .streaming else {
      return liveTranscriptionModel
    }

    guard localStreamingModelSource.hasPrefix("local/streaming/"),
      availableStreamingSourceIDs.contains(localStreamingModelSource)
    else {
      throw TranscriptionManagerError.invalidLocalStreamingSource(localStreamingModelSource)
    }

    return localStreamingModelSource
  }

  /// Returns the metadata for the live-transcription provider whose API key is
  /// missing — `nil` if the current live model needs no key, or its key is set.
  /// Used for the "API key required" pre-flight alert before a live recording.
  func missingLiveAPIKeyProvider() async -> TranscriptionProviderMetadata? {
    let model = appSettings.liveTranscriptionModel
    let registry = TranscriptionProviderRegistry.shared
    guard await registry.requiresAPIKey(for: model) else { return nil }
    guard let provider = await registry.provider(forModel: model) else { return nil }
    if await hasAPIKey(for: provider.metadata) { return nil }
    return provider.metadata
  }

  /// Reads the provider API key, mapping only a genuine "not found" to
  /// `apiKeyMissing`. Other keychain failures (locked keychain, denied access,
  /// unexpected status) are rethrown as-is so users aren't told to re-enter a
  /// key that exists.
  private func getAPIKey(for metadata: TranscriptionProviderMetadata) async throws -> String {
    do {
      return try await secureStorage.secret(identifier: metadata.apiKeyIdentifier)
    } catch SecureAppStorageError.valueNotFound {
      throw TranscriptionProviderError.apiKeyMissing
    }
  }

  private func hasAPIKey(for metadata: TranscriptionProviderMetadata) async -> Bool {
    await secureStorage.hasSecret(identifier: metadata.apiKeyIdentifier)
  }
}

extension TranscriptionManager: LiveTranscriptionSessionDelegate {
  func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
    livePartialText = text
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didUpdateWith update: LiveTranscriptionUpdate
  ) {
    livePartialText = update.text
    liveTextIsFinal = update.isFinal
    liveTextConfidence = update.confidence
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didFinishWith result: TranscriptionResult
  ) {
    // Guard against double-resume of continuation - the controllers have their own
    // guards but this is belt-and-suspenders safety
    guard let cont = continuation else {
      // Already finished or no continuation - log but don't crash
      print("[TranscriptionManager] didFinishWith called but no continuation (already finished?)")
      return
    }
    cancelStopTimeout()
    continuation = nil
    isLiveTranscribing = false
    livePartialText = result.text
    liveTextIsFinal = true
    liveTextConfidence = result.confidence
    cont.resume(returning: result)
  }

  func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) {
    if let cont = continuation {
      // We're in the middle of stopping - resume with the error
      cancelStopTimeout()
      continuation = nil
      isLiveTranscribing = false
      cont.resume(throwing: error)
    } else {
      // Error happened mid-session - store it for when stop is called
      pendingError = error
      // Keep isLiveTranscribing true so stopLiveTranscription doesn't throw early
    }
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didDetectUtteranceBoundary utterance: String
  ) {
    utteranceBoundaryText = utterance
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
