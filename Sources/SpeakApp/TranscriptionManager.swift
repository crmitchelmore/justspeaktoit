import AVFoundation
import Foundation
import Speech

enum TranscriptionManagerError: LocalizedError {
  case liveSessionAlreadyRunning
  case liveSessionNotRunning
  case recognizerUnavailable
  case permissionsMissing

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
    }
  }
}

@MainActor
final class TranscriptionManager: ObservableObject {
  @Published private(set) var livePartialText: String = ""
  @Published private(set) var isLiveTranscribing: Bool = false

  private let appSettings: AppSettings
  private let liveController: NativeOSXLiveTranscriber
  private let batchClient: BatchTranscriptionClient
  private let openRouter: OpenRouterAPIClient
  private let secureStorage: SecureAppStorage

  private var continuation: CheckedContinuation<TranscriptionResult, Error>?

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    batchClient: BatchTranscriptionClient,
    openRouter: OpenRouterAPIClient,
    secureStorage: SecureAppStorage
  ) {
    self.appSettings = appSettings
    self.liveController = NativeOSXLiveTranscriber(
      permissionsManager: permissionsManager,
      appSettings: appSettings
    )
    self.batchClient = batchClient
    self.openRouter = openRouter
    self.secureStorage = secureStorage
    self.liveController.delegate = self
  }

  func startLiveTranscription() async throws {
    guard !isLiveTranscribing else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
    liveController.configure(
      language: appSettings.preferredLocaleIdentifier,
      model: appSettings.liveTranscriptionModel
    )
    try await liveController.start()
    livePartialText = ""
    isLiveTranscribing = true
  }

  func stopLiveTranscription() async throws -> TranscriptionResult {
    guard isLiveTranscribing else { throw TranscriptionManagerError.liveSessionNotRunning }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      Task {
        await self.liveController.stop()
      }
    }
  }

  func cancelLiveTranscription() {
    guard isLiveTranscribing else { return }
    continuation?.resume(throwing: TranscriptionManagerError.liveSessionNotRunning)
    continuation = nil
    Task {
      await liveController.stop()
    }
    isLiveTranscribing = false
    livePartialText = ""
  }

  func transcribeFile(at url: URL) async throws -> TranscriptionResult {
    let model = appSettings.batchTranscriptionModel
    let registry = TranscriptionProviderRegistry.shared

    // Check if this model uses a dedicated transcription provider
    if let provider = await registry.provider(forModel: model) {
      let apiKey = try await getAPIKey(for: provider.metadata)
      return try await provider.transcribeFile(
        at: url,
        apiKey: apiKey,
        model: model,
        language: appSettings.preferredLocaleIdentifier
      )
    }

    // Fallback to OpenRouter for legacy models
    return try await batchClient.transcribeFile(
      at: url,
      model: model,
      language: appSettings.preferredLocaleIdentifier
    )
  }

  func batchTranscriptionUsesRemoteService() async -> Bool {
    let model = appSettings.batchTranscriptionModel
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

    let model = appSettings.batchTranscriptionModel
    let registry = TranscriptionProviderRegistry.shared

    // Check if provider has API key
    if let provider = await registry.provider(forModel: model) {
      return await hasAPIKey(for: provider.metadata)
    }

    // Fallback to OpenRouter
    return await openRouter.hasStoredAPIKey()
  }

  private func getAPIKey(for metadata: TranscriptionProviderMetadata) async throws -> String {
    guard let key = try? await secureStorage.secret(identifier: metadata.apiKeyIdentifier) else {
      throw TranscriptionProviderError.apiKeyMissing
    }
    return key
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
    didFinishWith result: TranscriptionResult
  ) {
    isLiveTranscribing = false
    livePartialText = result.text
    continuation?.resume(returning: result)
    continuation = nil
  }

  func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) {
    isLiveTranscribing = false
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

final class NativeOSXLiveTranscriber: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings
  private var speechRecognizer: SFSpeechRecognizer?
  private let audioEngine = AVAudioEngine()
  private var recognitionTask: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var currentLocaleIdentifier: String?
  private var currentModel: String?
  private var latestResult: SFSpeechRecognitionResult?

  init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
  }

  func configure(language: String?, model: String) {
    currentLocaleIdentifier = language
    currentModel = model
  }

  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.permissionsMissing
    }

    let localeIdentifier = currentLocaleIdentifier ?? appSettings.preferredLocaleIdentifier

    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
      throw TranscriptionManagerError.recognizerUnavailable
    }
    speechRecognizer = recognizer

    request = SFSpeechAudioBufferRecognitionRequest()
    request?.shouldReportPartialResults = true

    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.request?.append(buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()

    latestResult = nil
    recognitionTask = recognizer.recognitionTask(with: request!) { [weak self] result, error in
      guard let self else { return }
      if let result {
        self.latestResult = result
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.delegate?.liveTranscriber(
            self, didUpdatePartial: result.bestTranscription.formattedString)
          if result.isFinal {
            self.finish(with: result)
          }
        }
      } else if let error {
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.delegate?.liveTranscriber(self, didFail: error)
        }
      }
    }

    isRunning = true
  }

  func stop() async {
    guard isRunning else { return }
    request?.endAudio()
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionTask?.cancel()
    request = nil
    recognitionTask = nil
    isRunning = false

    if let result = latestResult, !result.isFinal {
      await MainActor.run {
        finish(with: result)
      }
    }
  }

  private func finish(with result: SFSpeechRecognitionResult) {
    let segments = result.bestTranscription.segments.map { segment in
      TranscriptionSegment(
        startTime: segment.timestamp,
        endTime: segment.timestamp + segment.duration,
        text: segment.substring
      )
    }

    let transcript = result.bestTranscription.formattedString
    let duration = (segments.last?.endTime ?? 0) - (segments.first?.startTime ?? 0)
    let outcome = TranscriptionResult(
      text: transcript,
      segments: segments,
      confidence: result.bestTranscription.segments.isEmpty
        ? nil
        : result
          .transcriptionSegmentsConfidence,
      duration: duration,
      modelIdentifier: currentModel ?? "apple/local/SFSpeechRecognizer",
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )

    delegate?.liveTranscriber(self, didFinishWith: outcome)
  }

  private func ensurePermissions() async -> Bool {
    let microphone = await permissionsManager.request(.microphone)
    let speech = await permissionsManager.request(.speechRecognition)
    return microphone.isGranted && speech.isGranted
  }
}

struct RemoteAudioTranscriber: BatchTranscriptionClient {
  let client: OpenRouterAPIClient

  func transcribeFile(at url: URL, model: String, language: String?) async throws
    -> TranscriptionResult
  {
    try await client.transcribeFile(at: url, model: model, language: language)
  }
}

extension SFSpeechRecognitionResult {
  fileprivate var transcriptionSegmentsConfidence: Double? {
    guard !bestTranscription.segments.isEmpty else { return nil }
    let confidences = bestTranscription.segments.map { Double($0.confidence) }
    let total = confidences.reduce(0, +)
    return total / Double(confidences.count)
  }
}
