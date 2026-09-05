import AVFoundation
import Foundation
import SpeakCore

/// macOS capture/controller path for providers implemented by a shared
/// `StreamingTranscriptionClient`.
///
/// Platform-specific code owns microphone capture and PCM conversion; the
/// provider transport and event parsing stay in SpeakCore and are shared with
/// iOS.
@MainActor
final class SharedClientLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning = false

  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private let appSettings: AppSettings

  private var currentLanguage: String?
  private var currentModel: String?
  private var client: StreamingTranscriptionClient?
  private var audioEngine = AVAudioEngine()
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var startedAt: Date?
  private var latestTranscript = ""
  /// Folds updates by the hosted client's declared final shape (issue #700);
  /// re-created in start() once the client is known.
  private var accumulated = TranscriptAccumulator(shape: .cumulativeTranscript)
  private var isStopping = false
  private var isStarting = false
  private let audioProcessor = SharedClientAudioProcessor()

  init(
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    secureStorage: SecureAppStorage,
    appSettings: AppSettings
  ) {
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.secureStorage = secureStorage
    self.appSettings = appSettings
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard !isRunning, !isStarting else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
    isStarting = true
    defer { isStarting = false }
    try Task.checkCancellation()
    let permission = await permissionsManager.ensureGranted(.microphone)
    try Task.checkCancellation()
    guard permission.isGranted else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }
    guard let model = currentModel,
          let route = LiveTranscriptionRouting.route(for: model),
          let keyIdentifier = route.apiKeyIdentifier else {
      throw LiveTranscriptionClientError.unknownModel(currentModel ?? "")
    }

    let apiKey = try await loadAPIKey(identifier: keyIdentifier)
    try Task.checkCancellation()
    guard let client = LiveTranscriptionClientFactory.makeClient(
      for: route,
      apiKey: apiKey,
      language: currentLanguage,
      keywords: [.meta, .google].contains(route.provider)
        ? MetaMuseVoiceTranscribe.keywords(from: appSettings.transcriptionKeywords)
        : []
    ) else {
      throw LiveTranscriptionClientError.providerNotAvailable(route.provider)
    }

    activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    audioEngine = AVAudioEngine()
    latestTranscript = ""
    accumulated = TranscriptAccumulator(shape: client.finalShape)
    isStopping = false
    self.client = client

    do {
      // A preferred-input session may have been acquired while cancellation
      // was pending; from here every exit must release it through cleanup.
      try Task.checkCancellation()
      client.start(
        onTranscript: { [weak self, weak client] text, isFinal in
          Task { @MainActor [weak self, weak client] in
            guard let self else { return }
            // Cached controllers are reused between recordings, so a message
            // queued by the previous stream can land here after the next
            // recording started. Only the current stream owns this state.
            guard LiveTranscriptionRun.isCurrent(client, activeStream: self.client) else { return }
            self.handleTranscript(text, isFinal: isFinal)
          }
        },
        onError: { [weak self, weak client] error in
          Task { @MainActor [weak self, weak client] in
            guard let self else { return }
            guard LiveTranscriptionRun.isCurrent(client, activeStream: self.client) else { return }
            self.delegate?.liveTranscriber(self, didFail: error)
          }
        }
      )
      try installAudioTap(route: route, client: client)
      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      try Task.checkCancellation()
      startedAt = Date()
      isRunning = true
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning, !isStopping else { return }
    isStopping = true
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    if let client {
      audioProcessor.drainConverterTail(to: client)
    }
    audioProcessor.setRunning(false)

    if let finalizingClient = client as? FinalizingStreamingTranscriptionClient {
      // Contract: `finishAndWait()` returns the session's full transcript, so
      // this replaces what we have rather than appending to it — appending
      // would double every word the client already streamed.
      if let finalTranscript = await finalizingClient.finishAndWait(),
         latestTranscript != finalTranscript {
        applyFullTranscript(finalTranscript)
      }
    } else {
      client?.stop()
    }
    client = nil
    isRunning = false
    isStopping = false

    let result = TranscriptionResult(
      text: latestTranscript,
      segments: [],
      confidence: nil,
      duration: startedAt.map { Date().timeIntervalSince($0) } ?? 0,
      modelIdentifier: currentModel ?? "",
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
    delegate?.liveTranscriber(self, didFinishWith: result)
    await endActiveInputSession()
  }

  private func loadAPIKey(identifier: String) async throws -> String {
    let apiKey: String
    do {
      apiKey = try await secureStorage.secret(identifier: identifier)
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error {
        throw TranscriptionProviderError.apiKeyMissing
      }
      throw error
    }
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TranscriptionProviderError.apiKeyMissing
    }
    return apiKey
  }

  /// Applies a transcript update, folded by the hosted client's declared
  /// final shape (issue #700): cumulative finals replace (xAI restates the
  /// whole turn on every event), standalone segment finals append — including
  /// repeated identical text, which is a genuine repeat, so a segment-shaped
  /// provider routed here can no longer lose earlier segments.
  private func handleTranscript(_ text: String, isFinal: Bool) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let displayText: String
    if isFinal {
      displayText = accumulated.append(final: trimmed)
    } else {
      displayText = accumulated.display(withInterim: trimmed)
    }
    latestTranscript = displayText
    delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
      text: displayText,
      isFinal: isFinal,
      confidence: nil
    ))
    delegate?.liveTranscriber(self, didUpdatePartial: displayText)
    if isFinal {
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: displayText)
    }
  }

  /// Adopts a transcript that is already complete (the `finishAndWait()`
  /// return) as the whole session transcript — replace, never append, or every
  /// word the client already streamed would double.
  private func applyFullTranscript(_ transcript: String) {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    accumulated.replace(with: trimmed)
    latestTranscript = accumulated.text
    delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
      text: accumulated.text,
      isFinal: true,
      confidence: nil
    ))
    delegate?.liveTranscriber(self, didUpdatePartial: accumulated.text)
    delegate?.liveTranscriber(self, didDetectUtteranceBoundary: accumulated.text)
  }

  private func installAudioTap(
    route: LiveTranscriptionRoute,
    client: StreamingTranscriptionClient
  ) throws {
    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(inputFormat) else {
      throw TranscriptionManagerError.noUsableAudioInput
    }
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(route.sampleRate),
      channels: 1,
      interleaved: true
    ), AVAudioConverter(from: inputFormat, to: targetFormat) != nil else {
      throw TranscriptionManagerError.noUsableAudioInput
    }

    let processor = audioProcessor
    processor.setRunning(true)
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
      processor.handleAudioTap(
        buffer,
        inputFormat: inputFormat,
        outputFormat: targetFormat,
        client: client
      )
    }
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    audioProcessor.setRunning(false)
    client?.stop()
    client = nil
    isRunning = false
    isStopping = false
    latestTranscript = ""
    accumulated.reset()
    startedAt = nil
    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}

/// Copies each tap buffer out of a pool and converts it off the render
/// thread, so the audio callback never allocates or blocks.
///
/// Mirrors the per-provider controllers on macOS: one converter cached per
/// input format, one reusable output buffer, and no `converter.reset()`
/// between chunks.
private final class SharedClientAudioProcessor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.speak.app.sharedClient.audioProcessing")
  private let copyBufferPool = LivePCMBufferPool(
    maximumBuffers: 4,
    tapBufferSize: 4096,
    label: "shared-client"
  )
  private let logger = SpeakLogger.logger(category: "SharedClientLiveController")
  private var isRunning = false
  private let converterCache = LiveConverterCache()
  private var reusableOutputBuffer: AVAudioPCMBuffer?

  func setRunning(_ running: Bool) {
    queue.sync {
      isRunning = running
      if !running {
        converterCache.reset()
        reusableOutputBuffer = nil
        copyBufferPool.removeAll()
      }
    }
  }

  /// Flushes the retained resampler's trailing frames down the live send path
  /// before the converter is released (issue #849).
  func drainConverterTail(to client: StreamingTranscriptionClient) {
    queue.sync {
      guard let tail = converterCache.drainPCM16() else { return }
      client.sendAudio(tail)
    }
  }

  func handleAudioTap(
    _ buffer: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat,
    client: StreamingTranscriptionClient
  ) {
    guard let copied = copyPCMBuffer(buffer) else { return }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.copyBufferPool.recycle(copied) }
      guard self.isRunning else { return }
      self.convertAndSend(copied, from: inputFormat, to: outputFormat, client: client)
    }
  }

  private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let frameLength = buffer.frameLength
    guard frameLength > 0,
          let copy = copyBufferPool.buffer(format: buffer.format, frameCapacity: frameLength) else {
      return nil
    }
    copy.frameLength = frameLength
    let source = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: buffer.audioBufferList)
    )
    let destination = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: copy.audioBufferList)
    )
    for index in 0..<min(source.count, destination.count) {
      let sourceBuffer = source[index]
      guard let sourceData = sourceBuffer.mData,
            let destinationData = destination[index].mData else { continue }
      destinationData.copyMemory(from: sourceData, byteCount: Int(sourceBuffer.mDataByteSize))
      destination[index].mDataByteSize = sourceBuffer.mDataByteSize
    }
    return copy
  }

  private func convertAndSend(
    _ buffer: AVAudioPCMBuffer,
    from inputFormat: AVAudioFormat,
    to outputFormat: AVAudioFormat,
    client: StreamingTranscriptionClient
  ) {
    guard let converter = converterCache.converter(from: inputFormat, to: outputFormat) else {
      logger.error("Failed to create audio converter")
      return
    }

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
    let output: AVAudioPCMBuffer
    if let reusable = reusableOutputBuffer, reusable.frameCapacity >= capacity {
      reusable.frameLength = 0
      output = reusable
    } else {
      guard let created = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        return
      }
      reusableOutputBuffer = created
      output = created
    }

    // No `converter.reset()` between chunks: `LiveConverterCache` owns the
    // retained converter and its end-of-stream drain (see issue #849).
    var conversionError: NSError?
    var didProvideInput = false
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      guard !didProvideInput else {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, conversionError == nil else {
      logger.error("Audio conversion failed")
      return
    }
    let frameCount = Int(output.frameLength)
    guard frameCount > 0, let samples = output.int16ChannelData else { return }
    client.sendAudio(Data(bytes: samples[0], count: frameCount * 2))
  }
}
