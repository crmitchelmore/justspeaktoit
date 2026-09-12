import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

// MARK: - Cartesia Live Controller

// swiftlint:disable type_body_length
@MainActor
final class CartesiaLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: CartesiaLiveTranscriber?
  private var currentLanguage: String?
  private var currentModel: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
  private let logger = SpeakLogger.logger(category: "CartesiaLiveController")
  private let audioProcessor = CartesiaAudioProcessor()
  private var hasFinished: Bool = false

  private let targetSampleRate: Double = 16_000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
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
    logger.info("Configured Cartesia with model: \(model)")
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let apiKey = try await cartesiaAPIKey()
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

      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: true
      ) else {
        throw CartesiaLiveError.connectionFailed
      }
      targetFormat = outputFormat

      let modelID: String
      if let model = currentModel, model.hasPrefix("cartesia/") {
        modelID = String(model.dropFirst("cartesia/".count))
          .replacingOccurrences(of: "-streaming", with: "")
      } else {
        modelID = "ink-2"
      }

      let newTranscriber = CartesiaTranscriptionProvider().createLiveTranscriber(
        apiKey: apiKey,
        model: modelID,
        sampleRate: 16_000
      )
      transcriber = newTranscriber

      newTranscriber.start(
        onTranscript: { [weak self, weak newTranscriber] text, isFinal in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            // Drop callbacks queued by a previous recording's stream: this
            // controller instance is reused between recordings (issue #643).
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
            self.handleTranscript(text: text, isFinal: isFinal)
          }
        },
        onError: { [weak self, weak newTranscriber] error in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
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
      isRunning = true
      streamingStartTime = Date()
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  private func handleTranscript(text: String, isFinal: Bool) {
    if isFinal {
      let segment = TranscriptionSegment(startTime: 0, endTime: 0, text: text)
      finalSegments.append(segment)
      fullTranscript = finalSegments.map(\.text).joined(separator: " ")
      currentInterim = ""
      delegate?.liveTranscriber(self, didUpdatePartial: fullTranscript)
    } else {
      currentInterim = text
      let displayText = fullTranscript.isEmpty
        ? currentInterim
        : fullTranscript + " " + currentInterim
      delegate?.liveTranscriber(self, didUpdatePartial: displayText)
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
      audioProcessor.drainConverterTail()
      audioProcessor.flushPendingAudio(to: transcriber)
      await transcriber.waitForPendingSends()
      audioProcessor.setRunning(false)
      await applyLiveStopGrace(appSettings.liveStopGracePeriod)
      transcriber.stop()
    } else {
      audioProcessor.setRunning(false)
    }

    let result = buildFinalResult()
    delegate?.liveTranscriber(self, didFinishWith: result)

    await endActiveInputSession()
    transcriber = nil
  }

  private final class CartesiaAudioProcessor: @unchecked Sendable {
    private static let preferredChunkBytes = CartesiaLiveTranscriber.preferredChunkBytes
    private static let minimumChunkBytes = CartesiaLiveTranscriber.minimumChunkBytes

    private let queue = DispatchQueue(label: "com.speak.app.cartesia.audioProcessing")
    private let copyBufferPool = LivePCMBufferPool(
      maximumBuffers: 4,
      tapBufferSize: 1024,
      label: "cartesia"
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

    func flushPendingAudio(to transcriber: CartesiaLiveTranscriber) {
      queue.sync {
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
      transcriber: CartesiaLiveTranscriber,
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
      transcriber: CartesiaLiveTranscriber,
      logger: Logger
    ) {
      guard let converter = converterCache.converter(from: inputFormat, to: outputFormat) else {
        logger.error("Failed to create audio converter")
        return
      }

      let ratio = outputFormat.sampleRate / inputFormat.sampleRate
      let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
      let outputBuffer: AVAudioPCMBuffer
      if let reusable = reusableOutputBuffer, reusable.frameCapacity >= outputFrameCapacity {
        reusable.frameLength = 0
        outputBuffer = reusable
      } else {
        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
          return
        }
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
      guard status != .error, error == nil else { return }
      guard let int16Data = outputBuffer.int16ChannelData else { return }
      let frameLength = Int(outputBuffer.frameLength)
      pendingPCMData.append(Data(bytes: int16Data[0], count: frameLength * 2))

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

private extension CartesiaLiveController {
  func ensurePermissions() async -> Bool {
    let microphone = await permissionsManager.ensureGranted(.microphone)
    return microphone.isGranted
  }

  func cartesiaAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "cartesia.apiKey")
      guard !apiKey.isEmpty else { throw CartesiaLiveError.missingAPIKey }
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error { throw CartesiaLiveError.missingAPIKey }
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
    streamingStartTime = nil
    currentInterim = ""
    finalSegments = []
    fullTranscript = ""
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
      modelIdentifier: currentModel ?? "cartesia/ink-2-streaming",
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
