// swiftlint:disable file_length
import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

// MARK: - Soniox Live Controller

// swiftlint:disable type_body_length
/// Wraps SonioxLiveTranscriber to conform to LiveTranscriptionController protocol.
final class SonioxLiveController: NSObject, LiveTranscriptionController, SonioxFinalizationDelegate {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: SonioxLiveTranscriber?
  private var currentLanguage: String?
  private var currentModel: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
  private let logger = SpeakLogger.logger(category: "SonioxLiveController")
  private let audioProcessor = SonioxAudioProcessor()
  private var hasFinished: Bool = false

  private let targetSampleRate: Double = 16000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  private var finalSegments: [TranscriptionSegment] = []
  private var currentInterim: String = ""
  private var fullTranscript: String = ""
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private var stopGeneration = LiveTranscriptionStopGeneration()

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

      let newTranscriber = SonioxLiveTranscriber(
        apiKey: apiKey,
        model: modelID,
        language: currentLanguage,
        sampleRate: 16000
      )
      transcriber = newTranscriber
      newTranscriber.finalizationDelegate = self

      newTranscriber.start(
        onTranscript: { [weak self, weak newTranscriber] text, isFinal in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            // Cached controllers are reused between recordings, so a message
            // queued by the previous stream can land here after the next
            // recording started. Only the current stream owns this state.
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
            self.handleTranscript(text: text, isFinal: isFinal)
          }
        },
        onError: { [weak self, weak newTranscriber] error in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
            // Always release a pending stop() continuation so we don't burn the
            // 2s timeout when an error/close arrives during shutdown.
            if let continuation = self.stopContinuation {
              self.stopContinuation = nil
              continuation.resume()
            }
            if !self.isRunning { return }
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

      // Resume the stop() continuation if we're shutting down.
      if hasFinished, let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }
    } else {
      currentInterim = text
      let displayText = fullTranscript.isEmpty
        ? currentInterim
        : fullTranscript + " " + currentInterim
      delegate?.liveTranscriber(self, didUpdatePartial: displayText)
    }
  }

  // MARK: - SonioxFinalizationDelegate

  nonisolated func sonioxDidFinishStream(_ transcriber: SonioxLiveTranscriber) {
    Task { @MainActor [weak self, weak transcriber] in
      guard let self else { return }
      guard LiveTranscriptionRun.isCurrent(transcriber, activeStream: self.transcriber) else { return }
      if let continuation = self.stopContinuation {
        self.stopContinuation = nil
        continuation.resume()
      }
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
      // Ask Soniox to finalize any in-flight non-final tokens so the trailing
      // words of the utterance get returned as final tokens. The server replies
      // with a `<fin>` marker token (handled in parseResponse) which fires the
      // SonioxFinalizationDelegate and resumes the continuation below.
      transcriber.sendFinalize()

      // Wait for `<fin>`/`finished:true` or a 2s timeout. Both paths nil-out
      // stopContinuation idempotently.
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

      // Now flush any accumulated finals (covers the timeout path) and close.
      transcriber.flushFinal()
      transcriber.signalEndOfStream()
      transcriber.stop()
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

  private final class SonioxAudioProcessor: @unchecked Sendable {
    private static let preferredChunkBytes = SonioxLiveTranscriber.preferredChunkBytes
    private static let minimumChunkBytes = SonioxLiveTranscriber.minimumChunkBytes

    private let queue = DispatchQueue(label: "com.speak.app.soniox.audioProcessing")
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

    func flushPendingAudio(to transcriber: SonioxLiveTranscriber) {
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
      transcriber: SonioxLiveTranscriber,
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
      transcriber: SonioxLiveTranscriber,
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

      // NOTE: We deliberately do NOT call converter.reset() between chunks —
      // doing so wipes the resampler's filter history and priming/trailing
      // frames, which audibly clicks at chunk boundaries and pays the
      // re-priming cost on every chunk. The converter is only created once
      // per inputFormat (cachedConverter), so its state is the *correct*
      // thing to preserve across taps.
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
    finalSegments = []
    currentInterim = ""
    fullTranscript = ""
    streamingStartTime = nil
    hasFinished = false
    stopContinuation = nil
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
