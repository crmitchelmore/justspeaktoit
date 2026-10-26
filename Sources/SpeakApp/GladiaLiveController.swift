// swiftlint:disable file_length
import AVFoundation
import Foundation
import os.log
import SpeakCore

@MainActor
// swiftlint:disable:next type_body_length
final class GladiaLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: GladiaLiveTranscriber?
  private var currentLanguage: String?
  private var currentModel: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
  private let logger = SpeakLogger.logger(category: "GladiaLiveController")
  private let audioProcessor = GladiaAudioProcessor()
  private var hasFinished: Bool = false

  private let targetSampleRate: Double = 16_000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  private var streamingEndTime: Date?
  private var finalSegments: [TranscriptionSegment] = []
  private var currentInterim: String = ""
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
    logger.info("Configured Gladia with model: \(model, privacy: .public)")
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let apiKey = try await gladiaAPIKey()
    activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    audioEngine = LiveInputEngines.shared.makeEngine()
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
        throw GladiaLiveError.connectionFailed
      }
      targetFormat = outputFormat

      let provider = GladiaTranscriptionProvider()
      let newTranscriber = provider.createLiveTranscriber(
        apiKey: apiKey,
        model: currentModel ?? appSettings.liveTranscriptionModel,
        language: currentLanguage,
        sampleRate: 16_000
      )
      transcriber = newTranscriber

      newTranscriber.start(
        onTranscript: { [weak self, weak newTranscriber] _ in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            // Cached controllers are reused between recordings, so a message
            // queued by the previous stream can land here after the next
            // recording started. Only the current stream owns this state.
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
            guard let newTranscriber else { return }
            self.applySnapshot(newTranscriber.snapshot)
          }
        },
        onError: { [weak self, weak newTranscriber] _ in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
            guard self.isRunning, let failure = newTranscriber?.takeFailureForReporting() else { return }
            self.delegate?.liveTranscriber(self, didFail: failure)
          }
        }
      )

      audioProcessor.setRunning(true)
      let processor = audioProcessor
      let log = logger
      try inputNode.installTapSafely(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
        processor.handleAudioTap(
          buffer,
          inputFormat: inputFormat,
          outputFormat: outputFormat,
          transcriber: newTranscriber,
          logger: log
        )
      }

      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      isRunning = true
      streamingStartTime = Date()
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning, !hasFinished else { return }
    hasFinished = true
    streamingEndTime = Date()
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    let active = transcriber
    let stoppingInputSession = activeInputSession
    activeInputSession = nil
    let budget = appSettings.liveModelCapabilities.postStopFinalizeBudget
    let grace = appSettings.liveStopGracePeriod
    if let active {
      audioProcessor.drainConverterTail()
      audioProcessor.flushPendingAudio(to: active)
    }
    audioProcessor.setRunning(false)
    if let active {
      await active.waitForPendingSends()
      await applyLiveStopGrace(grace)
      // The terminal waiter is installed before stop_recording can be sent.
      // A final utterance/acknowledgement is never session completion.
      let snapshot = await active.finishAndWait(timeout: budget)
      if let stoppingInputSession {
        await audioDeviceManager.endUsingPreferredInput(session: stoppingInputSession)
      }
      guard transcriber === active else { return }
      applySnapshot(snapshot)
      if let failure = active.takeFailureForReporting() {
        delegate?.liveTranscriber(self, didFail: failure)
      }
    } else if let stoppingInputSession {
      await audioDeviceManager.endUsingPreferredInput(session: stoppingInputSession)
    }
    guard transcriber === active else { return }
    delegate?.liveTranscriber(self, didFinishWith: buildFinalResult())
    if transcriber === active { transcriber = nil }
  }

  /// Every accepted final and its confidence is applied once even when an
  /// end_session resumes stop before queued MainActor transcript delivery.
  private func applySnapshot(_ snapshot: GladiaMacFinalization.Snapshot) {
    for event in snapshot.finals.dropFirst(finalSegments.count) {
      finalSegments.append(TranscriptionSegment(
        startTime: 0, endTime: 0, text: event.text, isFinal: true, confidence: event.confidence
      ))
      fullTranscript = finalSegments.map(\.text).joined(separator: " ")
      currentInterim = ""
      delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
        text: fullTranscript, isFinal: true, confidence: event.confidence
      ))
      delegate?.liveTranscriber(self, didUpdatePartial: fullTranscript)
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: event.text)
    }
    currentInterim = snapshot.interim?.text ?? ""
    if let interim = snapshot.interim {
      let display = fullTranscript.isEmpty ? interim.text : fullTranscript + " " + interim.text
      delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
        text: display, isFinal: false, confidence: interim.confidence
      ))
      delegate?.liveTranscriber(self, didUpdatePartial: display)
    }
  }

  private final class GladiaAudioProcessor: @unchecked Sendable {
    private static let minimumChunkBytes = GladiaLiveTranscriber.minimumChunkBytes
    private static let preferredChunkBytes = GladiaLiveTranscriber.preferredChunkBytes

    private let queue = DispatchQueue(label: "com.speak.app.gladia.audioProcessing")
    private let copyBufferPool = LivePCMBufferPool(
      maximumBuffers: 4,
      tapBufferSize: 1024,
      label: "gladia"
    )
    private var isRunning: Bool = false
    private let converterCache = LiveConverterCache()
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    private var pendingPCMData = Data()

    func setRunning(_ running: Bool) {
      queue.sync {
        isRunning = running
        if !running {
          converterCache.reset()
          reusableOutputBuffer = nil
          copyBufferPool.removeAll()
          pendingPCMData.removeAll(keepingCapacity: false)
        }
      }
    }

    /// Flushes the retained resampler's trailing frames into `pendingPCMData` so
    /// the final flush sends them (issue #849). The converter is finished once
    /// drained, so the cache releases it rather than reusing it.
    func drainConverterTail() {
      queue.sync {
        guard let tail = converterCache.drainPCM16() else { return }
        pendingPCMData.append(tail)
      }
    }

    func flushPendingAudio(to transcriber: GladiaLiveTranscriber) {
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
            contentsOf: repeatElement(0, count: Self.minimumChunkBytes - pendingPCMData.count))
        }
        transcriber.sendAudio(pendingPCMData)
        pendingPCMData.removeAll(keepingCapacity: false)
      }
    }

    func handleAudioTap(
      _ buffer: AVAudioPCMBuffer,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      transcriber: GladiaLiveTranscriber,
      logger: Logger
    ) {
      guard let copied = copyPCMBuffer(buffer) else { return }
      queue.async { [weak self] in
        guard let self else { return }
        defer { self.copyBufferPool.recycle(copied) }
        guard self.isRunning else { return }
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
      guard let copy = copyBufferPool.buffer(format: buffer.format, frameCapacity: frameLength) else {
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
      transcriber: GladiaLiveTranscriber,
      logger: Logger
    ) {
      guard let converter = converterCache.converter(from: inputFormat, to: outputFormat) else {
        logger.error("Failed to create Gladia audio converter")
        return
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

      // No `converter.reset()` between chunks: `LiveConverterCache` owns the
      // retained converter and its end-of-stream drain (see issue #849).
      var error: NSError?
      var didProvideInput = false
      let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        guard !didProvideInput else {
          outStatus.pointee = .noDataNow
          return nil
        }
        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
      }

      guard status != .error, error == nil else {
        logger.error("Gladia audio conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        return
      }

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

private extension GladiaLiveController {
  func ensurePermissions() async -> Bool {
    // Remote streaming providers only need microphone access; speech recognition
    // permission is exclusive to the on-device Apple transcriber.
    let microphone = await permissionsManager.ensureGranted(.microphone)
    return microphone.isGranted
  }

  func gladiaAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "gladia.apiKey")
      guard !apiKey.isEmpty else {
        throw GladiaLiveError.missingAPIKey
      }
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error {
        throw GladiaLiveError.missingAPIKey
      }
      throw error
    }
  }

  func resetStartState() {
    transcriber = nil
    targetFormat = nil
    finalSegments = []
    currentInterim = ""
    fullTranscript = ""
    streamingStartTime = nil
    streamingEndTime = nil
    hasFinished = false
    isRunning = false
  }

  func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)
    transcriber?.stop()
    transcriber = nil
    targetFormat = nil
    finalSegments = []
    currentInterim = ""
    fullTranscript = ""
    streamingStartTime = nil
    streamingEndTime = nil
    await endActiveInputSession()
  }

  func buildFinalResult() -> TranscriptionResult {
    var text = finalSegments.map(\.text).joined(separator: " ")
    let trimmedInterim = currentInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInterim.isEmpty {
      if !text.isEmpty { text += " " }
      text += trimmedInterim
    }

    let streamingDuration: TimeInterval
    if let startTime = streamingStartTime {
      streamingDuration = (streamingEndTime ?? Date()).timeIntervalSince(startTime)
    } else {
      streamingDuration = 0
    }

    return TranscriptionResult(
      text: text,
      segments: finalSegments,
      confidence: finalSegments.compactMap(\.confidence).average,
      duration: streamingDuration,
      modelIdentifier: currentModel ?? "gladia/solaria-1-streaming",
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}

private extension Array where Element == Double {
  var average: Double? {
    guard !isEmpty else { return nil }
    return reduce(0, +) / Double(count)
  }
}
