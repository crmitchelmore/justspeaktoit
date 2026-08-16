// swiftlint:disable file_length
import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

// MARK: - Modulate Live Controller

// swiftlint:disable type_body_length
/// Wraps Modulate's WebSocket streaming API to conform to LiveTranscriptionController.
final class ModulateLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: ModulateLiveTranscriber?
  private var currentModel: String?
  private var currentLanguage: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
  private let logger = SpeakLogger.logger(category: "ModulateLiveController")
  private let audioProcessor = ModulateAudioProcessor()
  private var hasFinished: Bool = false
  private let targetSampleRate: Double = 16_000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  private var utterances: [ModulateUtterance] = []
  private var streamDurationMs: Int?
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private var stopGeneration = LiveTranscriptionStopGeneration()
  private var sessionFeatureConfiguration = ModulateFeatureConfiguration(
    speakerDiarization: true,
    emotionSignal: false,
    accentSignal: false,
    piiPhiTagging: false
  )

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
    logger.info("Configured Modulate with model: \(model)")
  }

  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let apiKey = try await modulateAPIKey()
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
      let outputFormat = try makeModulateOutputFormat()
      let transcriber = try makeModulateTranscriber(apiKey: apiKey)
      installModulateTap(
        on: inputNode,
        inputFormat: inputFormat,
        outputFormat: outputFormat,
        transcriber: transcriber
      )

      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      isRunning = true
      streamingStartTime = Date()
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning else { return }
    guard !hasFinished else { return }
    hasFinished = true

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    if let transcriber {
      audioProcessor.flushPendingAudio(to: transcriber)
      await transcriber.waitForPendingSends()
      audioProcessor.setRunning(false)
      await applyLiveStopGrace(appSettings.liveStopGracePeriod)
      transcriber.signalEndOfStream()

      // Wait for the final response (resumed in finished/error callbacks) or a 2s timeout.
      // Both paths nil-out stopContinuation under the MainActor before resuming, so resume is idempotent.
      let generation = stopGeneration.begin()
      await withCheckedContinuation { continuation in
        stopContinuation = continuation
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(2))
          guard let self,
            self.stopGeneration.isCurrent(generation),
            let cont = self.stopContinuation
          else { return }
          self.stopContinuation = nil
          cont.resume()
        }
      }

      transcriber.cancel()
    } else {
      audioProcessor.setRunning(false)
    }

    let result = buildFinalResult()
    await MainActor.run {
      delegate?.liveTranscriber(self, didFinishWith: result)
    }

    await endActiveInputSession()
    transcriber = nil
  }

  private func handleUtterance(_ utterance: ModulateUtterance) {
    utterances.append(utterance)
    let transcript = sessionFeatureConfiguration.formattedTranscript(
      from: utterances,
      fallbackText: utterances.map(\.text).joined(separator: " ")
    )
    delegate?.liveTranscriber(self, didUpdatePartial: transcript)
    delegate?.liveTranscriber(self, didDetectUtteranceBoundary: utterance.text)
  }

  private func handleDone(durationMs: Int) {
    streamDurationMs = durationMs
    if let continuation = stopContinuation {
      stopContinuation = nil
      continuation.resume()
    }
  }

  private func buildFinalResult() -> TranscriptionResult {
    let text = sessionFeatureConfiguration.formattedTranscript(
      from: utterances,
      fallbackText: utterances.map(\.text).joined(separator: " ")
    )
    let segments = utterances.map { utterance in
      TranscriptionSegment(
        startTime: TimeInterval(utterance.startMs) / 1000,
        endTime: TimeInterval(utterance.startMs + utterance.durationMs) / 1000,
        text: sessionFeatureConfiguration.segmentText(for: utterance, within: utterances)
      )
    }

    let duration: TimeInterval
    if let streamDurationMs {
      duration = TimeInterval(streamDurationMs) / 1000
    } else if let startTime = streamingStartTime {
      duration = Date().timeIntervalSince(startTime)
    } else {
      duration = 0
    }

    let rawPayloadData = try? JSONEncoder().encode(
      ModulateLiveCapture(
        durationMs: streamDurationMs ?? Int(duration * 1000),
        utterances: utterances
      )
    )

    return TranscriptionResult(
      text: text,
      segments: segments,
      confidence: nil,
      duration: duration,
      modelIdentifier: currentModel ?? "modulate/velma-2-stt-streaming",
      cost: estimatedModulateStreamingCost(durationSeconds: duration),
      rawPayload: rawPayloadData.flatMap { String(data: $0, encoding: .utf8) },
      debugInfo: nil
    )
  }

  private func resetStartState() {
    transcriber = nil
    targetFormat = nil
    utterances = []
    streamDurationMs = nil
    stopContinuation = nil
    hasFinished = false
    isRunning = false
    streamingStartTime = nil
    sessionFeatureConfiguration = currentFeatureConfiguration()
  }

  private func makeModulateOutputFormat() throws -> AVAudioFormat {
    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: targetSampleRate,
      channels: 1,
      interleaved: true
    ) else {
      throw TranscriptionProviderError.invalidResponse
    }
    targetFormat = outputFormat
    return outputFormat
  }

  private func makeModulateTranscriber(apiKey: String) throws -> ModulateLiveTranscriber {
    let provider = ModulateTranscriptionProvider()
    let transcriber = provider.createLiveTranscriber(
      apiKey: apiKey,
      sampleRate: 16_000,
      featureConfiguration: sessionFeatureConfiguration
    )

    self.transcriber = transcriber
    transcriber.start(
      onUtterance: { [weak self, weak transcriber] utterance in
        Task { @MainActor [weak self, weak transcriber] in
          guard let self else { return }
          // Cached controllers are reused between recordings, so a message
          // queued by the previous stream can land here after the next
          // recording started. Only the current stream owns this state.
          guard LiveTranscriptionRun.isCurrent(transcriber, activeStream: self.transcriber) else { return }
          self.handleUtterance(utterance)
        }
      },
      onDone: { [weak self, weak transcriber] durationMs in
        Task { @MainActor [weak self, weak transcriber] in
          guard let self else { return }
          // Cached controllers are reused between recordings, so a message
          // queued by the previous stream can land here after the next
          // recording started. Only the current stream owns this state.
          guard LiveTranscriptionRun.isCurrent(transcriber, activeStream: self.transcriber) else { return }
          self.handleDone(durationMs: durationMs)
        }
      },
      onError: { [weak self, weak transcriber] error in
        Task { @MainActor [weak self, weak transcriber] in
          guard let self else { return }
          guard LiveTranscriptionRun.isCurrent(transcriber, activeStream: self.transcriber) else { return }
          self.handleStreamingError(error)
        }
      }
    )
    return transcriber
  }

  private func installModulateTap(
    on inputNode: AVAudioInputNode,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat,
    transcriber: ModulateLiveTranscriber
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

  private func handleStreamingError(_ error: Error) {
    let failedInputSession = activeInputSession
    activeInputSession = nil
    hasFinished = true
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    audioProcessor.setRunning(false)
    transcriber?.cancel()
    transcriber = nil
    targetFormat = nil
    isRunning = false

    if let continuation = stopContinuation {
      stopContinuation = nil
      continuation.resume()
    }

    Task { @MainActor [audioDeviceManager] in
      guard let failedInputSession else { return }
      await audioDeviceManager.endUsingPreferredInput(session: failedInputSession)
    }

    delegate?.liveTranscriber(self, didFail: error)
  }

  private func estimatedModulateStreamingCost(durationSeconds: TimeInterval) -> ChatCostBreakdown? {
    guard durationSeconds > 0 else { return nil }
    let hours = Decimal(durationSeconds / 3600)
    let totalCost = hours * Decimal(string: "0.06")!
    return ChatCostBreakdown(
      inputTokens: Int(durationSeconds),
      outputTokens: 0,
      totalCost: totalCost,
      currency: "USD"
    )
  }

  private func currentFeatureConfiguration() -> ModulateFeatureConfiguration {
    ModulateFeatureConfiguration(
      speakerDiarization: appSettings.modulateSpeakerDiarizationEnabled,
      emotionSignal: appSettings.modulateEmotionSignalEnabled,
      accentSignal: appSettings.modulateAccentSignalEnabled,
      piiPhiTagging: appSettings.modulatePIIPhiTaggingEnabled
    )
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)
    transcriber?.cancel()
    transcriber = nil
    targetFormat = nil
    streamingStartTime = nil
    utterances = []
    streamDurationMs = nil
    stopContinuation = nil
    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func ensurePermissions() async -> Bool {
    // Remote streaming providers only need microphone access; speech recognition
    // permission is exclusive to the on-device Apple transcriber.
    let microphone = await permissionsManager.ensureGranted(.microphone)
    return microphone.isGranted
  }

  private func modulateAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "modulate.apiKey")
      guard !apiKey.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error {
        throw TranscriptionProviderError.apiKeyMissing
      }
      throw error
    } catch {
      throw error
    }
  }
}

// swiftlint:disable nesting
private extension ModulateLiveController {
  struct ModulateLiveCapture: Encodable {
    let durationMs: Int
    let utterances: [ModulateUtterance]

    enum CodingKeys: String, CodingKey {
      case durationMs = "duration_ms"
      case utterances
    }
  }

  final class ModulateAudioProcessor: @unchecked Sendable {
    private static let minimumChunkBytes = 1600
    private static let preferredChunkBytes = 3200

    private let queue = DispatchQueue(label: "com.speak.app.modulate.audioProcessing")
    private var isRunning: Bool = false
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    private var pendingPCMData = Data()

    func setRunning(_ running: Bool) {
      queue.sync {
        isRunning = running
        if !running {
          cachedConverter = nil
          cachedInputFormat = nil
          reusableOutputBuffer = nil
          pendingPCMData.removeAll(keepingCapacity: false)
        }
      }
    }

    func flushPendingAudio(to transcriber: ModulateLiveTranscriber) {
      queue.sync {
        guard !pendingPCMData.isEmpty else { return }

        var offset = 0
        while pendingPCMData.count - offset >= Self.preferredChunkBytes {
          let chunk = pendingPCMData.subdata(in: offset..<(offset + Self.preferredChunkBytes))
          transcriber.sendAudio(chunk)
          offset += Self.preferredChunkBytes
        }
        if offset > 0 {
          pendingPCMData = Data(pendingPCMData.dropFirst(offset))
        }

        guard !pendingPCMData.isEmpty else { return }
        if pendingPCMData.count < Self.minimumChunkBytes {
          pendingPCMData.append(
            contentsOf: repeatElement(0, count: Self.minimumChunkBytes - pendingPCMData.count)
          )
        }
        transcriber.sendAudio(pendingPCMData)
        pendingPCMData.removeAll(keepingCapacity: false)
      }
    }

    func handleAudioTap(
      _ buffer: AVAudioPCMBuffer,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      transcriber: ModulateLiveTranscriber,
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
      transcriber: ModulateLiveTranscriber,
      logger: Logger
    ) {
      let converter: AVAudioConverter
      if let cached = cachedConverter, cachedInputFormat == inputFormat {
        converter = cached
      } else {
        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
          logger.error("Failed to create Modulate audio converter")
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
          pcmFormat: outputFormat,
          frameCapacity: outputFrameCapacity
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
      pendingPCMData.append(data)

      var offset = 0
      while pendingPCMData.count - offset >= Self.preferredChunkBytes {
        let chunk = pendingPCMData.subdata(in: offset..<(offset + Self.preferredChunkBytes))
        transcriber.sendAudio(chunk)
        offset += Self.preferredChunkBytes
      }
      if offset > 0 {
        pendingPCMData = Data(pendingPCMData.dropFirst(offset))
      }
    }
  }
}
// swiftlint:enable nesting
// swiftlint:enable type_body_length
