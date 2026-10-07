// swiftlint:disable file_length
import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

// MARK: - Soniox Live Controller

// swiftlint:disable type_body_length
/// Native capture with a thin adapter over the shared SonioxLiveClient.
final class SonioxLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: SonioxControllerClient?
  private var currentLanguage: String?
  private var currentModel: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
  private let logger = SpeakLogger.logger(category: "SonioxLiveController")
  private let audioProcessor = SonioxAudioProcessor()
  private var isStarting = false
  private var hasFinished: Bool = false

  private let targetSampleRate: Double = 16000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  private var reportedFailure = false

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
    logger.info("Configured Soniox with model: \(model)")
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func start() async throws {
    guard !isStarting, transcriber == nil else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
    isStarting = true
    defer { isStarting = false }
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let apiKey = try await sonioxAPIKey()
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
        throw SonioxLiveError.connectionFailed
      }
      targetFormat = outputFormat

      // Catalog ID like "soniox/stt-rt-v5-streaming" → API model "stt-rt-v5".
      let modelID: String
      if let model = currentModel, model.hasPrefix("soniox/") {
        modelID = String(model.dropFirst("soniox/".count))
          .replacingOccurrences(of: "-streaming", with: "")
      } else {
        modelID = "stt-rt-v5"
      }

      let newTranscriber = SonioxControllerClient(
        apiKey: apiKey,
        model: modelID,
        language: currentLanguage,
        sampleRate: 16000
      )
      transcriber = newTranscriber

      newTranscriber.start(
        onTranscript: { [weak self, weak newTranscriber] text, isFinal in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            // Cached controllers are reused between recordings, so a message
            // queued by the previous stream can land here after the next
            // recording started. Only the current stream owns this state.
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber),
                  !self.hasFinished else { return }
            self.handleTranscript(text: text, isFinal: isFinal)
          }
        },
        onError: { [weak self, weak newTranscriber] error in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
            await self.handleStreamError(error, from: newTranscriber)
          }
        }
      )

      audioProcessor.setRunning(true, stream: newTranscriber)
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
      // A stop can finish while a bad-device retry awaits. Keep another start
      // out until this attempt has retired, then clean up its engine normally.
      guard !hasFinished else { throw CancellationError() }
      if let error = newTranscriber.snapshot.error { throw error }
      isRunning = true
      streamingStartTime = Date()
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  private func handleTranscript(text: String, isFinal: Bool) {
    // Every shared Soniox update restates the whole recording. Appending it
    // to earlier finals duplicates confirmed words and punctuation revisions.
    delegate?.liveTranscriber(self, didUpdatePartial: text)
  }

  private func handleStreamError(_ error: Error, from active: SonioxControllerClient?) async {
    guard let active, LiveTranscriptionRun.isCurrent(active, activeStream: transcriber) else { return }
    // Startup inspects the synchronous error snapshot after the engine settles
    // and throws through its existing cleanup path before reporting success.
    guard isRunning || hasFinished else { return }
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)
    active.cancel()
    await endActiveInputSession()
    guard LiveTranscriptionRun.isCurrent(active, activeStream: transcriber), !reportedFailure else { return }
    reportedFailure = true
    delegate?.liveTranscriber(self, didUpdatePartial: active.snapshot.text)
    delegate?.liveTranscriber(self, didFail: error)
  }

  func stop() async {
    guard let active = transcriber, !hasFinished else { return }
    hasFinished = true
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    audioProcessor.drainConverterTail()
    audioProcessor.flushPendingAudio(to: active)
    audioProcessor.setRunning(false)
    await applyLiveStopGrace(appSettings.liveStopGracePeriod)
    guard LiveTranscriptionRun.isCurrent(active, activeStream: transcriber) else { return }
    // The shared client drains sends, sends end-of-stream and waits for the
    // server's finished response. The adapter's 3.5 s deadline preserves the
    // previous total failure budget without a healthy fixed finalisation wait.
    let snapshot = await active.finishAndWait()
    guard LiveTranscriptionRun.isCurrent(active, activeStream: transcriber) else { return }
    let result = buildFinalResult(snapshot)
    active.cancel()
    await endActiveInputSession()
    guard LiveTranscriptionRun.isCurrent(active, activeStream: transcriber) else { return }
    transcriber = nil
    if let error = snapshot.error {
      if !reportedFailure {
        reportedFailure = true
        delegate?.liveTranscriber(self, didUpdatePartial: snapshot.text)
        delegate?.liveTranscriber(self, didFail: error)
      }
    } else {
      delegate?.liveTranscriber(self, didFinishWith: result)
    }
  }

  private final class SonioxAudioProcessor: @unchecked Sendable {
    private static let preferredChunkBytes = SonioxControllerClient.preferredChunkBytes
    private static let minimumChunkBytes = SonioxControllerClient.minimumChunkBytes

    private let queue = DispatchQueue(label: "com.speak.app.soniox.audioProcessing")
    private let copyBufferPool = LivePCMBufferPool(
      maximumBuffers: 4,
      tapBufferSize: 1024,
      label: "soniox"
    )
    private var isRunning: Bool = false
    private var activeStreamID: ObjectIdentifier?
    private let converterCache = LiveConverterCache()
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    private var pendingPCMData = Data()

    func setRunning(_ running: Bool, stream: SonioxControllerClient? = nil) {
      queue.sync {
        isRunning = running
        activeStreamID = running ? stream.map(ObjectIdentifier.init) : nil
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

    func flushPendingAudio(to transcriber: SonioxControllerClient) {
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
      transcriber: SonioxControllerClient,
      logger: Logger
    ) {
      guard let copied = copyPCMBuffer(buffer) else { return }
      queue.async { [weak self] in
        guard let self else { return }
        defer { self.copyBufferPool.recycle(copied) }
        guard self.isRunning, self.activeStreamID == ObjectIdentifier(transcriber) else { return }
        self.processAndSendAudio(
          copied, from: inputFormat, to: outputFormat,
          transcriber: transcriber, logger: logger
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
      transcriber: SonioxControllerClient,
      logger: Logger
    ) {
      guard let converter = converterCache.converter(from: inputFormat, to: outputFormat) else {
        logger.error("Failed to create audio converter")
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
          pcmFormat: outputFormat, frameCapacity: outputFrameCapacity
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

private extension SonioxLiveController {
  func ensurePermissions() async -> Bool {
    // Remote streaming providers only need microphone access; speech recognition
    // permission is exclusive to the on-device Apple transcriber.
    let microphone = await permissionsManager.ensureGranted(.microphone)
    return microphone.isGranted
  }

  func sonioxAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "soniox.apiKey")
      guard !apiKey.isEmpty else { throw SonioxLiveError.missingAPIKey }
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error { throw SonioxLiveError.missingAPIKey }
      throw error
    }
  }

  func resetStartState() {
    transcriber = nil
    targetFormat = nil
    reportedFailure = false
    streamingStartTime = nil
    hasFinished = false
    isRunning = false
  }

  func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)
    transcriber?.cancel()
    transcriber = nil
    targetFormat = nil
    streamingStartTime = nil
    reportedFailure = false
    await endActiveInputSession()
  }

  func buildFinalResult(_ snapshot: SonioxControllerClient.Snapshot) -> TranscriptionResult {
    let segments = snapshot.confirmedText.isEmpty ? [] : [
      TranscriptionSegment(startTime: 0, endTime: 0, text: snapshot.confirmedText)
    ]
    let streamingDuration = streamingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    return TranscriptionResult(
      text: snapshot.text,
      segments: segments,
      confidence: nil,
      duration: streamingDuration,
      modelIdentifier: currentModel ?? "soniox/stt-rt-v5-streaming",
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
