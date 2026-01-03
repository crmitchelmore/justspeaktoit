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
  @Published private(set) var liveTextIsFinal: Bool = true
  @Published private(set) var liveTextConfidence: Double?
  @Published private(set) var isLiveTranscribing: Bool = false

  private let appSettings: AppSettings
  private let liveController: SwitchingLiveTranscriber
  private let batchClient: BatchTranscriptionClient
  private let openRouter: OpenRouterAPIClient
  private let secureStorage: SecureAppStorage

  private var continuation: CheckedContinuation<TranscriptionResult, Error>?
  private var pendingError: Error?

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
    let model = appSettings.liveTranscriptionModel
    let language = appSettings.preferredLocaleIdentifier
    print("[TranscriptionManager] startLiveTranscription - model: \(model), language: \(language)")
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
    // If there was a mid-session error, throw it now
    if let error = pendingError {
      pendingError = nil
      isLiveTranscribing = false
      throw error
    }
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
    isLiveTranscribing = false
    livePartialText = result.text
    liveTextIsFinal = true
    liveTextConfidence = result.confidence
    continuation?.resume(returning: result)
    continuation = nil
  }

  func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) {
    if continuation != nil {
      // We're in the middle of stopping - resume with the error
      continuation?.resume(throwing: error)
      continuation = nil
      isLiveTranscribing = false
    } else {
      // Error happened mid-session - store it for when stop is called
      pendingError = error
      // Keep isLiveTranscribing true so stopLiveTranscription doesn't throw early
    }
  }
}

final class NativeOSXLiveTranscriber: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings
  private let audioDeviceManager: AudioInputDeviceManager
  private var speechRecognizer: SFSpeechRecognizer?
  private let audioEngine = AVAudioEngine()
  private var recognitionTask: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var currentLocaleIdentifier: String?
  private var currentModel: String?
  private var latestResult: SFSpeechRecognitionResult?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?

  init(
    permissionsManager: PermissionsManager,
    appSettings: AppSettings,
    audioDeviceManager: AudioInputDeviceManager
  ) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
    self.audioDeviceManager = audioDeviceManager
  }

  func configure(language: String?, model: String) {
    currentLocaleIdentifier = language
    currentModel = model
  }

  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.permissionsMissing
    }

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()

    let localeIdentifier = currentLocaleIdentifier ?? appSettings.preferredLocaleIdentifier

    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw TranscriptionManagerError.recognizerUnavailable
    }
    speechRecognizer = recognizer

    request = SFSpeechAudioBufferRecognitionRequest()
    request?.shouldReportPartialResults = true
    // Prefer on-device recognition to avoid server errors
    if recognizer.supportsOnDeviceRecognition {
      request?.requiresOnDeviceRecognition = true
    }

    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.request?.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw error
    }

    latestResult = nil
    recognitionTask = recognizer.recognitionTask(with: request!) { [weak self] result, error in
      guard let self else { return }
      if let result {
        self.latestResult = result
        Task { @MainActor [weak self] in
          guard let self else { return }
          let text = result.bestTranscription.formattedString
          let confidence = result.bestTranscription.segments.isEmpty
            ? nil
            : result.transcriptionSegmentsConfidence
          let update = LiveTranscriptionUpdate(
            text: text,
            isFinal: result.isFinal,
            confidence: confidence
          )
          self.delegate?.liveTranscriber(self, didUpdateWith: update)
          self.delegate?.liveTranscriber(self, didUpdatePartial: text)
          if result.isFinal {
            self.finish(with: result)
          }
        }
      } else if let error {
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.delegate?.liveTranscriber(self, didFail: error)
        }
        Task { await self.endActiveInputSession() }
      }
    }

    activeInputSession = sessionContext
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

    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func finish(with result: SFSpeechRecognitionResult) {
    Task { await self.endActiveInputSession() }

    let segments = result.bestTranscription.segments.map { segment in
      TranscriptionSegment(
        startTime: segment.timestamp,
        endTime: segment.timestamp + segment.duration,
        text: segment.substring,
        isFinal: result.isFinal,
        confidence: Double(segment.confidence)
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

// MARK: - Deepgram Live Controller

import os.log

/// Wraps DeepgramLiveTranscriber to conform to LiveTranscriptionController protocol.
/// Resamples audio from device sample rate (typically 48kHz) to 16kHz for Deepgram.
final class DeepgramLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: DeepgramLiveTranscriber?
  private var currentLanguage: String?
  private var currentModel: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private let audioEngine = AVAudioEngine()
  private let logger = Logger(subsystem: "com.speak.app", category: "DeepgramLiveController")

  /// Deepgram's preferred audio format: 16kHz mono PCM16
  private let deepgramSampleRate: Double = 16000
  private var deepgramFormat: AVAudioFormat?

  /// Accumulated final transcript segments
  private var finalSegments: [TranscriptionSegment] = []
  /// Current interim text (not yet final)
  private var currentInterim: String = ""
  /// Full transcript so far (all finalized segments joined)
  private var fullTranscript: String = ""

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    secureStorage: SecureAppStorage
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.secureStorage = secureStorage
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
    logger.info("Configured Deepgram with model: \(model), language: \(language ?? "default")")
  }

  func start() async throws {
    print("[DeepgramLiveController] Starting Deepgram live transcription...")

    guard await ensurePermissions() else {
      print("[DeepgramLiveController] ERROR: Permissions missing")
      throw TranscriptionManagerError.permissionsMissing
    }

    let apiKey: String
    do {
      apiKey = try await secureStorage.secret(identifier: "deepgram.apiKey")
      guard !apiKey.isEmpty else {
        print("[DeepgramLiveController] ERROR: Deepgram API key is empty")
        throw DeepgramError.missingAPIKey
      }
      print("[DeepgramLiveController] API key retrieved (length: \(apiKey.count))")
    } catch {
      print("[DeepgramLiveController] ERROR: Failed to retrieve API key: \(error.localizedDescription)")
      throw DeepgramError.missingAPIKey
    }

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()
    activeInputSession = sessionContext

    // Reset state
    finalSegments = []
    currentInterim = ""
    fullTranscript = ""

    // Get audio format from device
    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    print("[DeepgramLiveController] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

    // Deepgram prefers 16kHz mono PCM16
    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: deepgramSampleRate,
      channels: 1,
      interleaved: true
    ) else {
      print("[DeepgramLiveController] ERROR: Failed to create output format")
      throw DeepgramError.connectionFailed
    }
    deepgramFormat = outputFormat
    print("[DeepgramLiveController] Output format: \(deepgramSampleRate)Hz mono PCM16")

    // Create transcriber with 16kHz sample rate (always)
    let provider = DeepgramTranscriptionProvider()
    print("[DeepgramLiveController] Creating transcriber with model: \(self.currentModel ?? "nova-2")")
    transcriber = provider.createLiveTranscriber(
      apiKey: apiKey,
      model: currentModel ?? "nova-2",
      language: currentLanguage,
      sampleRate: 16000  // Always 16kHz - we resample before sending
    )

    transcriber?.start(
      onTranscript: { [weak self] text, isFinal in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.handleTranscript(text: text, isFinal: isFinal)
        }
      },
      onError: { [weak self] error in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if !self.isRunning { return }
          print("[DeepgramLiveController] ERROR: \(error.localizedDescription)")
          self.delegate?.liveTranscriber(self, didFail: error)
        }
      }
    )

    // Set up audio capture with resampling to 16kHz
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      guard let self, self.isRunning else { return }
      // Process on background to avoid blocking audio thread
      Task.detached { [weak self] in
        await self?.processAndSendAudio(buffer, from: inputFormat, to: outputFormat)
      }
    }

    audioEngine.prepare()
    try audioEngine.start()
    isRunning = true
    print("[DeepgramLiveController] Started successfully")
  }

  /// Handle transcript from Deepgram - accumulate final segments, track interim
  private func handleTranscript(text: String, isFinal: Bool) {
    print("[DeepgramLiveController] Transcript: '\(text)' (final: \(isFinal))")

    if isFinal {
      // Commit this segment - create a basic segment (no timing from this callback)
      let segment = TranscriptionSegment(
        startTime: 0,
        endTime: 0,
        text: text
      )
      finalSegments.append(segment)
      fullTranscript = finalSegments.map(\.text).joined(separator: " ")
      currentInterim = ""
      print("[DeepgramLiveController] Final segment #\(finalSegments.count): '\(text.prefix(50))' - fullTranscript: '\(fullTranscript.prefix(80))'")

      // Notify delegate of updated full transcript
      delegate?.liveTranscriber(self, didUpdatePartial: fullTranscript)
    } else {
      // Update interim - display full transcript + current interim
      currentInterim = text
      let displayText = fullTranscript.isEmpty
        ? currentInterim
        : fullTranscript + " " + currentInterim

      delegate?.liveTranscriber(self, didUpdatePartial: displayText)
    }
  }

  /// Resample audio buffer from input format to 16kHz PCM16 and send to Deepgram.
  private func processAndSendAudio(
    _ buffer: AVAudioPCMBuffer,
    from inputFormat: AVAudioFormat,
    to outputFormat: AVAudioFormat
  ) async {
    guard isRunning, let transcriber else { return }

    // Create converter
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      logger.error("Failed to create audio converter")
      return
    }

    // Calculate output buffer size based on sample rate ratio
    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: outputFrameCapacity
    ) else { return }

    // Convert audio
    var error: NSError?
    let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    guard status != .error, error == nil else {
      logger.error("Audio conversion failed: \(error?.localizedDescription ?? "unknown")")
      return
    }

    // Extract PCM16 data and send
    guard let int16Data = outputBuffer.int16ChannelData else { return }
    let frameLength = Int(outputBuffer.frameLength)
    let data = Data(bytes: int16Data[0], count: frameLength * 2)

    transcriber.sendAudio(data)
  }

  func stop() async {
    print("[DeepgramLiveController] Stopping...")
    guard isRunning else { return }

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    let gracePeriod = max(appSettings.deepgramStopGracePeriod, 0)
    if gracePeriod > 0 {
      do {
        try await Task.sleep(nanoseconds: UInt64(gracePeriod * 1_000_000_000))
      } catch {
        // Ignored: sleep cancellation simply means we stop immediately.
      }
    }

    transcriber?.stop()

    // Build final result including any unfinalised interim text
    let result = buildFinalResult()
    print("[DeepgramLiveController] Built result: '\(result.text.prefix(100))' (\(result.text.count) chars)")

    await MainActor.run {
      delegate?.liveTranscriber(self, didFinishWith: result)
    }

    await endActiveInputSession()
    transcriber = nil
  }

  /// Build the final transcription result from accumulated segments
  private func buildFinalResult() -> TranscriptionResult {
    // Include any remaining interim text that wasn't finalized
    var text = finalSegments.map(\.text).joined(separator: " ")
    let trimmedInterim = currentInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInterim.isEmpty {
      if !text.isEmpty {
        text += " "
      }
      text += trimmedInterim
      print("[DeepgramLiveController] Including unfinalised interim: '\(trimmedInterim)'")
    }

    let duration = finalSegments.last?.endTime ?? 0

    return TranscriptionResult(
      text: text,
      segments: finalSegments,
      confidence: nil,
      duration: duration,
      modelIdentifier: currentModel ?? "deepgram/nova-2-streaming",
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func ensurePermissions() async -> Bool {
    let microphone = await permissionsManager.request(.microphone)
    let speech = await permissionsManager.request(.speechRecognition)
    return microphone.isGranted && speech.isGranted
  }
}

// MARK: - Switching Live Transcriber

/// Routes to appropriate live transcription controller based on selected model.
final class SwitchingLiveTranscriber: LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate? {
    didSet {
      nativeController.delegate = delegate
      deepgramController.delegate = delegate
    }
  }

  var isRunning: Bool {
    activeController?.isRunning ?? false
  }

  private let appSettings: AppSettings
  private let nativeController: NativeOSXLiveTranscriber
  private let deepgramController: DeepgramLiveController
  private var activeController: (any LiveTranscriptionController)?
  private var currentModel: String?

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    secureStorage: SecureAppStorage
  ) {
    self.appSettings = appSettings
    self.nativeController = NativeOSXLiveTranscriber(
      permissionsManager: permissionsManager,
      appSettings: appSettings,
      audioDeviceManager: audioDeviceManager
    )
    self.deepgramController = DeepgramLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
  }

  func configure(language: String?, model: String) {
    currentModel = model
    print("[SwitchingLiveTranscriber] Configured with model: \(model)")
    nativeController.configure(language: language, model: model)
    deepgramController.configure(language: language, model: model)
  }

  func start() async throws {
    let model = currentModel ?? appSettings.liveTranscriptionModel
    let useDeepgram = model.contains("deepgram")
    print("[SwitchingLiveTranscriber] Starting with model: \(model), useDeepgram: \(useDeepgram)")
    activeController = useDeepgram ? deepgramController : nativeController
    try await activeController?.start()
  }

  func stop() async {
    print("[SwitchingLiveTranscriber] Stopping...")
    await activeController?.stop()
    activeController = nil
  }
}
