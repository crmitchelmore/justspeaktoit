@preconcurrency import AVFoundation
import Foundation
import os.log
import SpeakCore
// swiftlint:disable type_body_length
@MainActor
final class SpeechmaticsLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning = false
  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: SpeechmaticsLiveTranscriber?
  private var currentLanguage: String?
  private var currentModel: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
  private let logger = Logger(subsystem: "com.speak.app", category: "SpeechmaticsLiveController")
  private let audioProcessor = SpeechmaticsAudioProcessor()
  private var hasFinished = false
  private let targetSampleRate: Double = 16000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  private var finalSegments: [TranscriptionSegment] = []
  private var currentInterim = ""
  private var fullTranscript = ""

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
    self.currentLanguage = language
    self.currentModel = model
    self.logger.info("Configured Speechmatics with model: \(model, privacy: .public)")
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.permissionsMissing
    }

    let apiKey = try await speechmaticsAPIKey()
    self.activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    self.audioEngine = AVAudioEngine()
    resetStartState()

    do {
      let inputNode = audioEngine.inputNode
      inputNode.removeTap(onBus: 0)
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard audioInputFormatIsUsable(inputFormat) else {
        throw TranscriptionManagerError.noUsableAudioInput
      }

      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: true
      ) else {
        throw SpeechmaticsLiveError.encodingFailed
      }
      self.targetFormat = outputFormat

      let provider = SpeechmaticsTranscriptionProvider()
      let newTranscriber = provider.createLiveTranscriber(
        apiKey: apiKey,
        model: currentModel ?? appSettings.liveTranscriptionModel,
        language: currentLanguage,
        sampleRate: 16000
      )
      self.transcriber = newTranscriber

      newTranscriber.start(
        onTranscript: { [weak self] event in
          Task { @MainActor [weak self] in
            self?.handleTranscript(event)
          }
        },
        onError: { [weak self] error in
          Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.hasFinished else { return }
            self.delegate?.liveTranscriber(self, didFail: error)
          }
        }
      )

      audioProcessor.setRunning(true)
      let processor = audioProcessor
      let log = logger
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
        processor.handleAudioTap(
          buffer,
          inputFormat: inputFormat,
          outputFormat: outputFormat,
          transcriber: newTranscriber,
          logger: log
        )
      }

      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      self.isRunning = true
      self.streamingStartTime = Date()
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning else { return }
    guard !hasFinished else { return }
    self.hasFinished = true

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    self.isRunning = false

    if let transcriber {
      audioProcessor.flushPendingAudio(to: transcriber)
      let recognitionStarted = await transcriber.waitForRecognitionStarted(
        timeout: appSettings.liveModelCapabilities.postStopFinalizeBudget
      )
      await transcriber.waitForPendingSends()
      audioProcessor.setRunning(false)
      if recognitionStarted {
        await applyLiveStopGrace(appSettings.liveStopGracePeriod)
        transcriber.sendEndOfStream()
        await transcriber.waitForPendingSends()
        await transcriber.awaitEndOfTranscript(timeout: appSettings.liveModelCapabilities.postStopFinalizeBudget)
      }
      transcriber.stop()
    } else {
      audioProcessor.setRunning(false)
    }

    let result = buildFinalResult()
    delegate?.liveTranscriber(self, didFinishWith: result)

    await endActiveInputSession()
    self.transcriber = nil
  }

  private func handleTranscript(_ event: SpeechmaticsTranscriptEvent) {
    if event.isFinal {
      let segment = TranscriptionSegment(
        startTime: event.startTime,
        endTime: event.endTime,
        text: event.text,
        isFinal: true,
        confidence: event.confidence
      )
      finalSegments.append(segment)
      fullTranscript = finalSegments.map(\.text).joined(separator: " ")
      currentInterim = ""
      delegate?.liveTranscriber(self, didUpdatePartial: fullTranscript)
      delegate?.liveTranscriber(
        self,
        didUpdateWith: LiveTranscriptionUpdate(text: fullTranscript, isFinal: true, confidence: event.confidence)
      )
    } else {
      currentInterim = event.text
      let displayText = fullTranscript.isEmpty ? currentInterim : fullTranscript + " " + currentInterim
      delegate?.liveTranscriber(self, didUpdatePartial: displayText)
      delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(text: displayText, isFinal: false))
    }
  }

  private final class SpeechmaticsAudioProcessor: @unchecked Sendable {
    private static let preferredChunkBytes = SpeechmaticsLiveTranscriber.preferredChunkBytes
    private static let minimumChunkBytes = SpeechmaticsLiveTranscriber.minimumChunkBytes

    private let queue = DispatchQueue(label: "com.speak.app.speechmatics.audioProcessing")
    private var isRunning = false
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    private var pendingPCMData = Data()

    func setRunning(_ running: Bool) {
      queue.sync {
        self.isRunning = running
        if !running {
          self.cachedConverter = nil
          self.cachedInputFormat = nil
          self.reusableOutputBuffer = nil
          self.pendingPCMData.removeAll(keepingCapacity: false)
        }
      }
    }

    func flushPendingAudio(to transcriber: SpeechmaticsLiveTranscriber) {
      queue.sync {
        guard !self.pendingPCMData.isEmpty else { return }
        var offset = 0
        while self.pendingPCMData.count - offset >= Self.preferredChunkBytes {
          let chunk = self.pendingPCMData.subdata(in: offset..<(offset + Self.preferredChunkBytes))
          transcriber.sendAudio(chunk)
          offset += Self.preferredChunkBytes
        }
        if offset > 0 {
          self.pendingPCMData = Data(self.pendingPCMData.dropFirst(offset))
        }
        guard !self.pendingPCMData.isEmpty else { return }
        if self.pendingPCMData.count < Self.minimumChunkBytes {
          self.pendingPCMData.append(
            contentsOf: repeatElement(0, count: Self.minimumChunkBytes - self.pendingPCMData.count))
        }
        transcriber.sendAudio(self.pendingPCMData)
        self.pendingPCMData.removeAll(keepingCapacity: false)
      }
    }

    func handleAudioTap(
      _ buffer: AVAudioPCMBuffer,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      transcriber: SpeechmaticsLiveTranscriber,
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
        let srcBuf = src[idx]
        guard let srcData = srcBuf.mData, let dstData = dst[idx].mData else { continue }
        dstData.copyMemory(from: srcData, byteCount: Int(srcBuf.mDataByteSize))
        dst[idx].mDataByteSize = srcBuf.mDataByteSize
      }
      return copy
    }

    // swiftlint:disable:next function_body_length
    private func processAndSendAudio(
      _ buffer: AVAudioPCMBuffer,
      from inputFormat: AVAudioFormat,
      to outputFormat: AVAudioFormat,
      transcriber: SpeechmaticsLiveTranscriber,
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
        self.cachedConverter = newConverter
        self.cachedInputFormat = inputFormat
        converter = newConverter
      }

      let ratio = outputFormat.sampleRate / inputFormat.sampleRate
      let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

      let outputBuffer: AVAudioPCMBuffer
      if let reusableOutputBuffer, reusableOutputBuffer.frameCapacity >= outputFrameCapacity {
        reusableOutputBuffer.frameLength = 0
        outputBuffer = reusableOutputBuffer
      } else {
        guard let newBuffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: outputFrameCapacity
        ) else { return }
        self.reusableOutputBuffer = newBuffer
        outputBuffer = newBuffer
      }

      converter.reset()
      var error: NSError?
      var suppliedInput = false
      let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        guard !suppliedInput else {
          outStatus.pointee = .noDataNow
          return nil
        }
        suppliedInput = true
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
// swiftlint:enable type_body_length
private extension SpeechmaticsLiveController {
  func ensurePermissions() async -> Bool {
    let microphone = await permissionsManager.ensureGranted(.microphone)
    let speech = await permissionsManager.ensureGranted(.speechRecognition)
    return microphone.isGranted && speech.isGranted
  }

  func speechmaticsAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "speechmatics.apiKey")
      guard !apiKey.isEmpty else { throw SpeechmaticsLiveError.missingAPIKey }
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error { throw SpeechmaticsLiveError.missingAPIKey }
      throw error
    }
  }

  func resetStartState() {
    self.transcriber = nil
    self.targetFormat = nil
    self.finalSegments = []
    self.currentInterim = ""
    self.fullTranscript = ""
    self.streamingStartTime = nil
    self.hasFinished = false
    self.isRunning = false
  }

  func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    self.isRunning = false
    audioProcessor.setRunning(false)
    transcriber?.stop()
    self.transcriber = nil
    self.targetFormat = nil
    self.streamingStartTime = nil
    self.currentInterim = ""
    self.finalSegments = []
    self.fullTranscript = ""
    await endActiveInputSession()
  }

  func buildFinalResult() -> TranscriptionResult {
    var text = finalSegments.map(\.text).joined(separator: " ")
    let trimmedInterim = currentInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInterim.isEmpty {
      if !text.isEmpty { text += " " }
      text += trimmedInterim
    }
    let streamingDuration = streamingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    return TranscriptionResult(
      text: text,
      segments: finalSegments,
      confidence: nil,
      duration: streamingDuration,
      modelIdentifier: currentModel ?? "speechmatics/enhanced-streaming",
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    self.activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}
