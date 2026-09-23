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
  private var run: SharedClientControllerRun?
  private var displayedRevision: UInt64 = 0
  private var displayedTranscriptRevision: UInt64 = 0
  var stopCompletionTimeout: TimeInterval {
    guard let budget = (client as? FinalizingStreamingTranscriptionClient)?.finalisationBudget,
          budget.isFinite, budget > 0 else { return 10 }
    return max(10, budget + 1)
  }

  private var isStopping = false
  private var isStarting = false
  private let audioProcessor = SharedClientAudioProcessor()
  // Injectable system boundaries for controller lifecycle tests.
  var clientFactory: (() -> StreamingTranscriptionClient)?
  var startCaptureAudio: (() async throws -> Void)?
  var enqueueClientUpdate: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { update in
    Task { @MainActor in update() }
  }

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

  func start() async throws {
        guard !isRunning, !isStarting, !isStopping else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
        isStarting = true
        defer { isStarting = false }
        try Task.checkCancellation()
    guard let model = currentModel,
          let route = LiveTranscriptionRouting.route(for: model),
          let keyIdentifier = route.apiKeyIdentifier else {
      throw LiveTranscriptionClientError.unknownModel(currentModel ?? "")
    }

    let client = try await makeClient(route: route, keyIdentifier: keyIdentifier)
    if startCaptureAudio == nil {
      activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    }
    audioEngine = AVAudioEngine()
    let active = SharedClientControllerRun(shape: client.finalShape, modelIdentifier: route.modelID)
    run = active
    displayedRevision = 0
    displayedTranscriptRevision = 0
    isStopping = false
    self.client = client

    do {
      // A preferred-input session may have been acquired while cancellation
      // was pending; from here every exit must release it through cleanup.
      try Task.checkCancellation()
      let enqueue = enqueueClientUpdate
      client.start(
        onTranscript: { [weak self] text, isFinal in
          guard let snapshot = active.receive(text, isFinal: isFinal) else { return }
          enqueue { [weak self] in self?.apply(snapshot, from: active) }
        },
        onError: { [weak self] error in
          guard let snapshot = active.fail(error) else { return }
          enqueue { [weak self] in self?.apply(snapshot, from: active) }
        }
      )
      if let failure = active.snapshot.error { throw failure }
      if let startCaptureAudio {
        try await startCaptureAudio()
      } else {
        try installAudioTap(route: route, client: client)
        try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      }
      try Task.checkCancellation()
      if let failure = active.snapshot.error { throw failure }
      startedAt = Date()
      isRunning = true
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning, !isStopping, let active = run, let activeClient = client else { return }
    isStopping = true
    defer { isStopping = false }
    audioEngine.stop()
    if startCaptureAudio == nil { audioEngine.inputNode.removeTap(onBus: 0) }
    audioProcessor.drainConverterTail(to: activeClient)
    audioProcessor.setRunning(false)

    let whole: String?
    if let finalizing = activeClient as? FinalizingStreamingTranscriptionClient {
      whole = await withTaskCancellationHandler {
        await finalizing.finishAndWait()
      } onCancel: { [weak self] in
        Task { @MainActor [weak self] in
          guard self?.run === active, active.cancel() else { return }
          activeClient.cancel()
        }
      }
    } else {
      if Task.isCancelled {
        if active.cancel() { activeClient.cancel() }
      } else {
        activeClient.stop()
      }
      whole = nil
    }
    if Task.isCancelled, active.cancel() { activeClient.cancel() }
    guard run === active, client === activeClient else { return }
    var snapshot = active.finish(whole: whole, cancelled: Task.isCancelled)
    // Read the synchronous state before retiring identity. Queued provider
    // errors must reach the owner before a stop can be mistaken for success.
    apply(snapshot, from: active, terminal: true)
    // A delegate can cancel synchronously while receiving the terminal text.
    // Publish that cancellation before success or retirement of this run.
    if Task.isCancelled, snapshot.error == nil {
      snapshot = active.finish(whole: nil, cancelled: true)
      activeClient.cancel()
      apply(snapshot, from: active, terminal: true)
    }
    isRunning = false
    if snapshot.error == nil {
      delegate?.liveTranscriber(self, didFinishWith: TranscriptionResult(
        text: snapshot.text, segments: [], confidence: nil,
        duration: startedAt.map { Date().timeIntervalSince($0) } ?? 0,
        modelIdentifier: active.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil
      ))
    }
    client = nil
    run = nil
    await endActiveInputSession()
  }

  private func makeClient(route: LiveTranscriptionRoute, keyIdentifier: String) async throws
    -> StreamingTranscriptionClient {
    if let clientFactory { return clientFactory() }
    let permission = await permissionsManager.ensureGranted(.microphone)
    try Task.checkCancellation()
    guard permission.isGranted else { throw TranscriptionManagerError.microphonePermissionMissing }
    let apiKey = try await loadAPIKey(identifier: keyIdentifier)
    try Task.checkCancellation()
    guard let created = LiveTranscriptionClientFactory.makeClient(
      for: route, apiKey: apiKey, language: currentLanguage,
      keywords: [.meta, .google].contains(route.provider)
        ? MetaMuseVoiceTranscribe.keywords(from: appSettings.transcriptionKeywords) : [],
      azureEndpoint: UserDefaults.standard.string(forKey: AzureSpeechConfiguration.endpointDefaultsKey) ?? ""
    ) else { throw LiveTranscriptionClientError.providerNotAvailable(route.provider) }
    return created
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

  private func apply(
    _ snapshot: SharedClientControllerRun.Snapshot,
    from active: SharedClientControllerRun,
    terminal: Bool = false
  ) {
    guard run === active, terminal || !isStopping, snapshot.revision > displayedRevision else { return }
    displayedRevision = snapshot.revision
    if snapshot.transcriptRevision > displayedTranscriptRevision {
      displayedTranscriptRevision = snapshot.transcriptRevision
      delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
        text: snapshot.text, isFinal: snapshot.isFinal && snapshot.error == nil, confidence: nil
      ))
      delegate?.liveTranscriber(self, didUpdatePartial: snapshot.text)
      if run === active, snapshot.isFinal, snapshot.error == nil, !terminal || !Task.isCancelled {
        delegate?.liveTranscriber(self, didDetectUtteranceBoundary: snapshot.text)
      }
    }
    if let failure = active.takeFailure() {
      delegate?.liveTranscriber(self, didFail: failure)
    }
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
    if startCaptureAudio == nil { audioEngine.inputNode.removeTap(onBus: 0) }
    audioProcessor.setRunning(false)
    run?.cancel()
    client?.cancel()
    client = nil
    run = nil
    isRunning = false
    isStopping = false
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
