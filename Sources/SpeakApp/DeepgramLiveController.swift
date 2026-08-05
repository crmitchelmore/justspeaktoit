// swiftlint:disable file_length
import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

// MARK: - Deepgram Live Controller

/// Drives the shared `SpeakCore.DeepgramLiveClient` behind the
/// `LiveTranscriptionController` protocol: macOS owns capture and resampling
/// (device rate, typically 48kHz → 16kHz PCM16), the client owns the Deepgram
/// transport and event parsing for both nova (`v1/listen`) and Flux
/// (`v2/listen`) models.
final class DeepgramLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: DeepgramLiveClient?
  private var currentLanguage: String?
  private var currentModel: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
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
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let apiKey = try await deepgramAPIKey()
    activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    audioEngine = AVAudioEngine()
    resetStartState()

    do {
      let inputNode = audioEngine.inputNode
      inputNode.removeTap(onBus: 0)
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard audioInputFormatIsUsable(inputFormat) else {
        throw TranscriptionManagerError.noUsableAudioInput
      }
      print("[DeepgramLiveController] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

      let outputFormat = try makeDeepgramOutputFormat()
      let transcriber = try makeDeepgramTranscriber(apiKey: apiKey)
      installDeepgramTap(
        on: inputNode,
        inputFormat: inputFormat,
        outputFormat: outputFormat,
        transcriber: transcriber
      )

      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      isRunning = true
      streamingStartTime = Date()
      print("[DeepgramLiveController] Started successfully")
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
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
      if fullTranscript.isEmpty {
        fullTranscript = text
      } else {
        fullTranscript += " " + text
      }
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
      transcriber: DeepgramLiveClient,
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
      transcriber: DeepgramLiveClient,
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

    await applyLiveStopGrace(appSettings.liveStopGracePeriod)

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
}

private extension DeepgramLiveController {
  func ensurePermissions() async -> Bool {
    // Remote streaming providers only need microphone access; speech recognition
    // permission is exclusive to the on-device Apple transcriber.
    let microphone = await permissionsManager.ensureGranted(.microphone)
    return microphone.isGranted
  }

  func deepgramAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "deepgram.apiKey")
      guard !apiKey.isEmpty else {
        print("[DeepgramLiveController] ERROR: Deepgram API key is empty")
        throw DeepgramError.missingAPIKey
      }
      print("[DeepgramLiveController] API key retrieved")
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error {
        print("[DeepgramLiveController] ERROR: Deepgram API key is missing")
        throw DeepgramError.missingAPIKey
      }
      print("[DeepgramLiveController] ERROR: Failed to retrieve API key: \(error.localizedDescription)")
      throw error
    } catch {
      print("[DeepgramLiveController] ERROR: Failed to retrieve API key: \(error.localizedDescription)")
      throw error
    }
  }

  func resetStartState() {
    transcriber = nil
    deepgramFormat = nil
    finalSegments = []
    currentInterim = ""
    fullTranscript = ""
    streamingStartTime = nil
    hasFinished = false
    isRunning = false
  }

  func makeDeepgramOutputFormat() throws -> AVAudioFormat {
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
    return outputFormat
  }

  func makeDeepgramTranscriber(apiKey: String) throws -> DeepgramLiveClient {
    let provider = DeepgramTranscriptionProvider()
    print("[DeepgramLiveController] Creating transcriber with model: \(currentModel ?? "nova-3")")
    let transcriber = provider.createLiveTranscriber(
      apiKey: apiKey,
      model: currentModel ?? "nova-3",
      language: currentLanguage,
      sampleRate: 16000
    )
    transcriber.start(
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
    self.transcriber = transcriber
    return transcriber
  }

  func installDeepgramTap(
    on inputNode: AVAudioInputNode,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat,
    transcriber: DeepgramLiveClient
  ) {
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
  }

  func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)
    transcriber?.stop()
    transcriber = nil
    deepgramFormat = nil
    streamingStartTime = nil
    finalSegments = []
    currentInterim = ""
    fullTranscript = ""
    await endActiveInputSession()
  }

  func buildFinalResult() -> TranscriptionResult {
    var text = finalSegments.map(\.text).joined(separator: " ")
    let trimmedInterim = currentInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInterim.isEmpty {
      if !text.isEmpty {
        text += " "
      }
      text += trimmedInterim
      print("[DeepgramLiveController] Including unfinalised interim (length: \(trimmedInterim.count))")
    }

    let streamingDuration: TimeInterval
    if let startTime = streamingStartTime {
      streamingDuration = Date().timeIntervalSince(startTime)
    } else {
      streamingDuration = finalSegments.last?.endTime ?? 0
    }

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

  func estimateDeepgramCost(durationSeconds: TimeInterval, model: String?) -> ChatCostBreakdown? {
    guard durationSeconds > 0 else { return nil }

    let minutes = durationSeconds / 60.0
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
      pricePerMinute = Decimal(string: "0.0077")!
    }

    let totalCost = Decimal(minutes) * pricePerMinute
    return ChatCostBreakdown(
      inputTokens: Int(durationSeconds),
      outputTokens: 0,
      totalCost: totalCost,
      currency: "USD"
    )
  }

  func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}
