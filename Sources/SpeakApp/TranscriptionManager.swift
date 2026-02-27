import SpeakCore
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
  @Published private(set) var utteranceBoundaryText: String?

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
      // Safety timeout: if the delegate never calls back, resume with an error
      // rather than hanging forever.
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard let self, let cont = self.continuation else { return }
        print("[TranscriptionManager] Safety timeout: continuation not resumed after 10s, forcing error")
        self.continuation = nil
        self.isLiveTranscribing = false
        cont.resume(throwing: TranscriptionManagerError.liveSessionNotRunning)
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
    // Guard against double-resume of continuation - the controllers have their own
    // guards but this is belt-and-suspenders safety
    guard let cont = continuation else {
      // Already finished or no continuation - log but don't crash
      print("[TranscriptionManager] didFinishWith called but no continuation (already finished?)")
      return
    }
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
  /// Guards against calling finish() more than once per session.
  private var hasFinished: Bool = false
  /// Accumulated text from recognition segments finalised mid-session (on pause).
  private var committedText: String = ""
  /// Monotonic counter incremented on each recognition restart so that
  /// error callbacks from cancelled tasks are ignored.
  private var recognitionGeneration: Int = 0

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
    hasFinished = false
    committedText = ""
    recognitionGeneration = 0
    guard request != nil else {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw TranscriptionManagerError.recognizerUnavailable
    }
    startRecognitionTask(with: recognizer)

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

    // Always ensure the delegate is called so the continuation in
    // TranscriptionManager is resumed.  If a recognition callback Task
    // already dispatched finish(), the hasFinished guard prevents a
    // double-resume.
    // Bump generation to suppress error callbacks from the cancelled task.
    recognitionGeneration += 1
    await MainActor.run {
      guard !self.hasFinished else { return }
      if let result = self.latestResult {
        self.finish(with: result)
      } else if !self.committedText.isEmpty {
        // No latest result but we have committed text from finalised segments.
        self.hasFinished = true
        let outcome = TranscriptionResult(
          text: self.committedText,
          segments: [],
          confidence: nil,
          duration: 0,
          modelIdentifier: self.currentModel ?? "apple/local/SFSpeechRecognizer",
          cost: nil,
          rawPayload: nil,
          debugInfo: nil
        )
        self.delegate?.liveTranscriber(self, didFinishWith: outcome)
      } else {
        // No results received (e.g. very short recording / silence).
        // Synthesise an empty result so the continuation isn't orphaned.
        self.hasFinished = true
        let empty = TranscriptionResult(
          text: "",
          segments: [],
          confidence: nil,
          duration: 0,
          modelIdentifier: self.currentModel ?? "apple/local/SFSpeechRecognizer",
          cost: nil,
          rawPayload: nil,
          debugInfo: nil
        )
        self.delegate?.liveTranscriber(self, didFinishWith: empty)
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
    // Guard against double finish - can happen if recognition callback delivers
    // a final result at the same time stop() is called
    guard !hasFinished else { return }
    hasFinished = true
    
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

    let currentText = result.bestTranscription.formattedString
    let fullText = committedText.isEmpty ? currentText : committedText + " " + currentText
    let duration = (segments.last?.endTime ?? 0) - (segments.first?.startTime ?? 0)
    let outcome = TranscriptionResult(
      text: fullText,
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

  // MARK: - Recognition task lifecycle

  /// Creates and starts a recognition task, routing results through the
  /// accumulation logic so that mid-session `isFinal` events commit text
  /// rather than clearing it.
  private func startRecognitionTask(with recognizer: SFSpeechRecognizer) {
    let generation = recognitionGeneration
    guard let activeRequest = request else { return }
    recognitionTask = recognizer.recognitionTask(with: activeRequest) { [weak self] result, error in
      guard let self else { return }
      if let result {
        self.latestResult = result
        Task { @MainActor [weak self] in
          guard let self, generation == self.recognitionGeneration else { return }
          let currentText = result.bestTranscription.formattedString
          let displayText = self.committedText.isEmpty
            ? currentText
            : self.committedText + " " + currentText
          let confidence = result.bestTranscription.segments.isEmpty
            ? nil
            : result.transcriptionSegmentsConfidence
          let update = LiveTranscriptionUpdate(
            text: displayText,
            isFinal: false,
            confidence: confidence
          )
          self.delegate?.liveTranscriber(self, didUpdateWith: update)
          self.delegate?.liveTranscriber(self, didUpdatePartial: displayText)
          if result.isFinal {
            print("[NativeOSXLiveTranscriber] Mid-session isFinal – "
              + "committing \(displayText.count) chars, restarting")
            self.committedText = displayText
            self.restartRecognitionTask()
          }
        }
      } else if let error {
        Task { @MainActor [weak self] in
          guard let self, generation == self.recognitionGeneration else { return }
          self.delegate?.liveTranscriber(self, didFail: error)
        }
        Task { [weak self] in
          guard let self else { return }
          let shouldEnd = await MainActor.run { generation == self.recognitionGeneration }
          if shouldEnd { await self.endActiveInputSession() }
        }
      }
    }
  }

  /// Restart recognition after a mid-session `isFinal` so continued speech
  /// is captured without losing previously committed text.
  @MainActor
  private func restartRecognitionTask() {
    guard isRunning, let recognizer = speechRecognizer else { return }

    recognitionGeneration += 1
    recognitionTask?.cancel()
    recognitionTask = nil

    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      newRequest.requiresOnDeviceRecognition = true
    }
    request = newRequest
    latestResult = nil

    startRecognitionTask(with: recognizer)
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
  private let audioProcessor = DeepgramAudioProcessor()
  /// Guards against calling didFinishWith more than once per session.
  private var hasFinished: Bool = false

  /// Deepgram's preferred audio format: 16kHz mono PCM16
  private let deepgramSampleRate: Double = 16000
  private var deepgramFormat: AVAudioFormat?

  /// Track streaming session start time for cost estimation
  private var streamingStartTime: Date?

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
    streamingStartTime = nil
    hasFinished = false

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
    print("[DeepgramLiveController] Creating transcriber with model: \(self.currentModel ?? "nova-3")")
    transcriber = provider.createLiveTranscriber(
      apiKey: apiKey,
      model: currentModel ?? "nova-3",
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

    guard let transcriber else {
      throw DeepgramError.connectionFailed
    }

    // Set up audio capture with resampling to 16kHz.
    // IMPORTANT: Copy the buffer before leaving the audio tap callback.
    audioProcessor.setRunning(true)
    let processor = audioProcessor
    let log = logger
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
      processor.handleAudioTap(
        buffer,
        inputFormat: inputFormat,
        outputFormat: outputFormat,
        transcriber: transcriber,
        logger: log
      )
    }

    audioEngine.prepare()
    try audioEngine.start()
    isRunning = true
    streamingStartTime = Date()
    print("[DeepgramLiveController] Started successfully")
  }

  /// Handle transcript from Deepgram - accumulate final segments, track interim
  private func handleTranscript(text: String, isFinal: Bool) {
    print("[DeepgramLiveController] Transcript received (length: \(text.count), final: \(isFinal))")

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
      print("[DeepgramLiveController] Final segment #\(finalSegments.count) (length: \(text.count)) - fullTranscript length: \(fullTranscript.count)")

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

  private final class DeepgramAudioProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.speak.app.deepgram.audioProcessing")
    private var isRunning: Bool = false

    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?

    func setRunning(_ running: Bool) {
      queue.sync {
        isRunning = running
        if !running {
          cachedConverter = nil
          cachedInputFormat = nil
          reusableOutputBuffer = nil
        }
      }
    }

    func handleAudioTap(
      _ buffer: AVAudioPCMBuffer,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      transcriber: DeepgramLiveTranscriber,
      logger: Logger
    ) {
      guard let copied = copyPCMBuffer(buffer) else { return }
      queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.processAndSendAudio(
          copied,
          from: inputFormat,
          to: outputFormat,
          transcriber: transcriber,
          logger: logger
        )
      }
    }

    private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
      let frameLength = buffer.frameLength
      guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameLength) else {
        return nil
      }
      copy.frameLength = frameLength

      let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
      let dst = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
      for idx in 0..<min(src.count, dst.count) {
        let srcBuffer = src[idx]
        guard let srcData = srcBuffer.mData, let dstData = dst[idx].mData else { continue }
        dstData.copyMemory(from: srcData, byteCount: Int(srcBuffer.mDataByteSize))
        dst[idx].mDataByteSize = srcBuffer.mDataByteSize
      }
      return copy
    }

    private func processAndSendAudio(
      _ buffer: AVAudioPCMBuffer,
      from inputFormat: AVAudioFormat,
      to outputFormat: AVAudioFormat,
      transcriber: DeepgramLiveTranscriber,
      logger: Logger
    ) {
      // Get or create cached converter (avoids ~30 allocations/sec)
      let converter: AVAudioConverter
      if let cached = cachedConverter, cachedInputFormat == inputFormat {
        converter = cached
      } else {
        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
          logger.error("Failed to create audio converter")
          return
        }
        cachedConverter = newConverter
        cachedInputFormat = inputFormat
        converter = newConverter
      }

      // Calculate output buffer size based on sample rate ratio
      let ratio = outputFormat.sampleRate / inputFormat.sampleRate
      let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

      // Reuse output buffer if possible (avoids allocation per chunk)
      let outputBuffer: AVAudioPCMBuffer
      if let reusable = reusableOutputBuffer, reusable.frameCapacity >= outputFrameCapacity {
        reusable.frameLength = 0  // Reset for reuse
        outputBuffer = reusable
      } else {
        guard let newBuffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: outputFrameCapacity
        ) else { return }
        reusableOutputBuffer = newBuffer
        outputBuffer = newBuffer
      }

      // Convert audio
      converter.reset()
      var error: NSError?
      let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      guard status != .error, error == nil else {
        let errorDescription = error?.localizedDescription ?? "unknown"
        logger.error("Audio conversion failed: \(errorDescription, privacy: .public)")
        return
      }

      // Extract PCM16 data and send
      guard let int16Data = outputBuffer.int16ChannelData else { return }
      let frameLength = Int(outputBuffer.frameLength)
      let data = Data(bytes: int16Data[0], count: frameLength * 2)
      transcriber.sendAudio(data)
    }
  }

  func stop() async {
    print("[DeepgramLiveController] Stopping...")
    guard isRunning else { return }
    // Guard against double finish - this should only be called once per session
    guard !hasFinished else {
      print("[DeepgramLiveController] Already finished, skipping duplicate stop")
      return
    }
    hasFinished = true

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    audioProcessor.setRunning(false)

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
    print("[DeepgramLiveController] Built result (\(result.text.count) chars)")

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
      print("[DeepgramLiveController] Including unfinalised interim (length: \(trimmedInterim.count))")
    }

    // Calculate duration from streaming session
    let streamingDuration: TimeInterval
    if let startTime = streamingStartTime {
      streamingDuration = Date().timeIntervalSince(startTime)
    } else {
      streamingDuration = finalSegments.last?.endTime ?? 0
    }

    // Estimate cost based on Deepgram pricing
    // Nova-3 (monolingual): $0.0077/minute
    let cost = estimateDeepgramCost(durationSeconds: streamingDuration, model: currentModel)

    return TranscriptionResult(
      text: text,
      segments: finalSegments,
      confidence: nil,
      duration: streamingDuration,
      modelIdentifier: currentModel ?? "deepgram/nova-3-streaming",
      cost: cost,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  /// Estimate Deepgram streaming cost based on duration and model
  /// Pricing reference: https://deepgram.com/pricing
  private func estimateDeepgramCost(durationSeconds: TimeInterval, model: String?) -> ChatCostBreakdown? {
    guard durationSeconds > 0 else { return nil }

    let minutes = durationSeconds / 60.0

    // Deepgram pricing per minute (PAYG, single channel)
    // Nova-3 (Monolingual): $0.0077/min
    // Nova-1 & 2: $0.0058/min
    // Enhanced: $0.0165/min
    // Base: $0.0145/min
    let pricePerMinute: Decimal
    let modelName = model?.lowercased() ?? "nova-3"

    if modelName.contains("nova-3") {
      pricePerMinute = Decimal(string: "0.0077")!
    } else if modelName.contains("nova") {
      pricePerMinute = Decimal(string: "0.0058")!
    } else if modelName.contains("enhanced") {
      pricePerMinute = Decimal(string: "0.0165")!
    } else if modelName.contains("base") {
      pricePerMinute = Decimal(string: "0.0145")!
    } else {
      // Default to Nova-3 pricing
      pricePerMinute = Decimal(string: "0.0077")!
    }

    let totalCost = Decimal(minutes) * pricePerMinute

    // Deepgram doesn't use tokens, but we can represent duration as "input" for display
    // Using seconds as "tokens" for the breakdown display
    return ChatCostBreakdown(
      inputTokens: Int(durationSeconds),
      outputTokens: 0,
      totalCost: totalCost,
      currency: "USD"
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

// MARK: - AssemblyAI Live Controller

/// Wraps AssemblyAILiveTranscriber to conform to LiveTranscriptionController protocol.
/// Resamples audio from device sample rate (typically 48kHz) to 16kHz for AssemblyAI.
final class AssemblyAILiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: AssemblyAILiveTranscriber?
  private var currentModel: String?
  private var currentLanguage: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private let audioEngine = AVAudioEngine()
  private let logger = Logger(subsystem: "com.speak.app", category: "AssemblyAILiveController")
  private let audioProcessor = AssemblyAIAudioProcessor()
  private var hasFinished: Bool = false

  private let targetSampleRate: Double = 16000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  private var finalSegments: [TranscriptionSegment] = []
  private var currentInterim: String = ""
  private var fullTranscript: String = ""
  private var currentTurnOrder: Int = -1
  private var finalSegmentIndexByTurnOrder: [Int: Int] = [:]
  private let formatTurnsEnabled: Bool = true
  private var stopContinuation: CheckedContinuation<Void, Never>?

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
    currentModel = model
    currentLanguage = language
    logger.info("Configured AssemblyAI with model: \(model)")
  }

  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.permissionsMissing
    }

    let apiKey: String
    do {
      apiKey = try await secureStorage.secret(identifier: "assemblyai.apiKey")
      guard !apiKey.isEmpty else { throw AssemblyAIError.missingAPIKey }
    } catch {
      throw AssemblyAIError.missingAPIKey
    }

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()
    activeInputSession = sessionContext

    finalSegments = []
    currentInterim = ""
    fullTranscript = ""
    currentTurnOrder = -1
    finalSegmentIndexByTurnOrder = [:]
    streamingStartTime = nil
    hasFinished = false

    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)

    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: targetSampleRate,
      channels: 1,
      interleaved: true
    ) else {
      throw AssemblyAIError.connectionFailed
    }
    targetFormat = outputFormat

    // AssemblyAI streaming only supports keyterms_prompt — the preprocessing prompt
    // is applied post-transcription by PostProcessingManager, not by the streaming API.
    let keyterms = appSettings.assemblyAIKeyterms
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let provider = AssemblyAITranscriptionProvider()
    transcriber = provider.createLiveTranscriber(
      apiKey: apiKey,
      sampleRate: 16000,
      keyterms: keyterms,
      language: currentLanguage
    )

    transcriber?.start(
      onTranscript: { [weak self] turn in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.handleTurn(turn)
        }
      },
      onError: { [weak self] error in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if !self.isRunning { return }
          self.delegate?.liveTranscriber(self, didFail: error)
        }
      }
    )

    guard let transcriber else { throw AssemblyAIError.connectionFailed }

    audioProcessor.setRunning(true)
    let processor = audioProcessor
    let log = logger
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
      processor.handleAudioTap(
        buffer,
        inputFormat: inputFormat,
        outputFormat: outputFormat,
        transcriber: transcriber,
        logger: log
      )
    }

    audioEngine.prepare()
    try audioEngine.start()
    isRunning = true
    streamingStartTime = Date()
  }

  private func handleTurn(_ turn: AssemblyAITurnResponse) {
    guard !turn.transcript.isEmpty || turn.end_of_turn else { return }

    let eot = turn.end_of_turn
    let fmt = turn.turn_is_formatted
    logger.debug("Turn: order=\(turn.turn_order) end=\(eot) formatted=\(fmt) len=\(turn.transcript.count)")

    if let langCode = turn.language_code {
      logger.info("Detected language: \(langCode) (confidence: \(turn.language_confidence ?? 0))")
    }

    // Utterance boundary — trigger immediate polish before end-of-turn
    if let utterance = turn.utterance, !utterance.isEmpty {
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: utterance)
    }

    if turn.end_of_turn {
      if formatTurnsEnabled && !turn.turn_is_formatted {
        // Unformatted end-of-turn: show as interim — formatted version is coming next
        currentInterim = turn.transcript
        rebuildDisplay()
        return
      }

      // Definitive final (formatted if enabled, or unformatted if format_turns is off)
      let segment = TranscriptionSegment(startTime: 0, endTime: 0, text: turn.transcript)

      if let existingIndex = finalSegmentIndexByTurnOrder[turn.turn_order],
        finalSegments.indices.contains(existingIndex)
      {
        finalSegments[existingIndex] = segment
      } else {
        finalSegments.append(segment)
        finalSegmentIndexByTurnOrder[turn.turn_order] = finalSegments.count - 1
      }

      fullTranscript = finalSegments.map(\.text).joined(separator: " ")
      currentInterim = ""
      currentTurnOrder = -1
      delegate?.liveTranscriber(self, didUpdatePartial: fullTranscript)

      // Signal stop() that the final turn has been captured
      if hasFinished, let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }
    } else {
      // Ongoing turn — replace interim (AssemblyAI sends full turn text each time)
      currentTurnOrder = turn.turn_order

      var displayTranscript = turn.transcript
      if let lastWord = turn.words?.last, !lastWord.word_is_final {
        if !displayTranscript.isEmpty {
          displayTranscript += " "
        }
        displayTranscript += lastWord.text
      }
      currentInterim = displayTranscript
      rebuildDisplay()
    }
  }

  private func rebuildDisplay() {
    let displayText = fullTranscript.isEmpty
      ? currentInterim
      : fullTranscript + " " + currentInterim
    delegate?.liveTranscriber(self, didUpdatePartial: displayText)
  }

  // Audio processor that resamples and forwards to AssemblyAI
  private final class AssemblyAIAudioProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.speak.app.assemblyai.audioProcessing")
    private var isRunning: Bool = false
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?

    func setRunning(_ running: Bool) {
      queue.sync {
        isRunning = running
        if !running {
          cachedConverter = nil
          cachedInputFormat = nil
          reusableOutputBuffer = nil
        }
      }
    }

    func handleAudioTap(
      _ buffer: AVAudioPCMBuffer,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      transcriber: AssemblyAILiveTranscriber,
      logger: Logger
    ) {
      guard let copied = copyPCMBuffer(buffer) else { return }
      queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.processAndSendAudio(
          copied, from: inputFormat, to: outputFormat,
          transcriber: transcriber, logger: logger
        )
      }
    }

    private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
      let frameLength = buffer.frameLength
      guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameLength) else {
        return nil
      }
      copy.frameLength = frameLength
      let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
      let dst = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
      for idx in 0..<min(src.count, dst.count) {
        let srcBuf = src[idx]
        guard let srcData = srcBuf.mData, let dstData = dst[idx].mData else { continue }
        dstData.copyMemory(from: srcData, byteCount: Int(srcBuf.mDataByteSize))
        dst[idx].mDataByteSize = srcBuf.mDataByteSize
      }
      return copy
    }

    private func processAndSendAudio(
      _ buffer: AVAudioPCMBuffer,
      from inputFormat: AVAudioFormat,
      to outputFormat: AVAudioFormat,
      transcriber: AssemblyAILiveTranscriber,
      logger: Logger
    ) {
      let converter: AVAudioConverter
      if let cached = cachedConverter, cachedInputFormat == inputFormat {
        converter = cached
      } else {
        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
          logger.error("Failed to create audio converter")
          return
        }
        cachedConverter = newConverter
        cachedInputFormat = inputFormat
        converter = newConverter
      }

      let ratio = outputFormat.sampleRate / inputFormat.sampleRate
      let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

      let outputBuffer: AVAudioPCMBuffer
      if let reusable = reusableOutputBuffer, reusable.frameCapacity >= outputFrameCapacity {
        reusable.frameLength = 0
        outputBuffer = reusable
      } else {
        guard let newBuffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat, frameCapacity: outputFrameCapacity
        ) else { return }
        reusableOutputBuffer = newBuffer
        outputBuffer = newBuffer
      }

      converter.reset()
      var error: NSError?
      let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      guard status != .error, error == nil else { return }

      guard let int16Data = outputBuffer.int16ChannelData else { return }
      let frameLength = Int(outputBuffer.frameLength)
      let data = Data(bytes: int16Data[0], count: frameLength * 2)
      transcriber.sendAudio(data)
    }
  }

  func stop() async {
    guard isRunning else { return }
    guard !hasFinished else { return }
    hasFinished = true

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)

    // Wait for the final Turn response triggered by ForceEndpoint, with a timeout.
    if transcriber != nil {
      transcriber?.stop()
      await withTaskGroup(of: Void.self) { group in
        group.addTask { @MainActor [weak self] in
          await withCheckedContinuation { continuation in
            self?.stopContinuation = continuation
          }
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(2))
        }
        // Return as soon as either the final turn arrives or the timeout fires
        await group.next()
        group.cancelAll()
      }
      stopContinuation = nil
    }

    let result = buildFinalResult()
    await MainActor.run {
      delegate?.liveTranscriber(self, didFinishWith: result)
    }

    await endActiveInputSession()
    transcriber = nil
  }

  private func buildFinalResult() -> TranscriptionResult {
    logger.info(
      "Building result: segments=\(self.finalSegments.count) interim=\(self.currentInterim.count) chars"
    )
    var text = finalSegments.map(\.text).joined(separator: " ")
    let trimmedInterim = currentInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInterim.isEmpty {
      if !text.isEmpty { text += " " }
      text += trimmedInterim
    }

    let streamingDuration: TimeInterval
    if let startTime = streamingStartTime {
      streamingDuration = Date().timeIntervalSince(startTime)
    } else {
      streamingDuration = 0
    }

    return TranscriptionResult(
      text: text,
      segments: finalSegments,
      confidence: nil,
      duration: streamingDuration,
      modelIdentifier: currentModel ?? "assemblyai/universal-streaming",
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
      assemblyAIController.delegate = delegate
    }
  }

  var isRunning: Bool {
    activeController?.isRunning ?? false
  }

  private let appSettings: AppSettings
  private let nativeController: NativeOSXLiveTranscriber
  private let deepgramController: DeepgramLiveController
  private let assemblyAIController: AssemblyAILiveController
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
    self.assemblyAIController = AssemblyAILiveController(
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
    assemblyAIController.configure(language: language, model: model)
  }

  func start() async throws {
    let model = currentModel ?? appSettings.liveTranscriptionModel
    print("[SwitchingLiveTranscriber] Starting with model: \(model)")
    if model.contains("assemblyai") {
      activeController = assemblyAIController
    } else if model.contains("deepgram") {
      activeController = deepgramController
    } else {
      activeController = nativeController
    }
    try await activeController?.start()
  }

  func stop() async {
    print("[SwitchingLiveTranscriber] Stopping...")
    await activeController?.stop()
    activeController = nil
  }

}
