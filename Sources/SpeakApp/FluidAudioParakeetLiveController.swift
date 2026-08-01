@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import OSLog
import SpeakCore

@MainActor
final class FluidAudioParakeetLiveController: LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let modelManager: FluidAudioModelManager
  private var audioEngine = AVAudioEngine()
  private var audioPump: FluidAudioBufferPump?
  private var transcriptPump: FluidAudioTranscriptPump?
  private var transcriber: StreamingEouAsrManager?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var currentLanguage: String?
  private var currentModel = FluidAudioParakeetModel.id
  private var streamingStartTime: Date?
  private var latestText = ""
  private var processingError: Error?
  private var isStopping = false
  private let logger = Logger(subsystem: "com.github.speakapp", category: "FluidAudioLive")

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    modelManager: FluidAudioModelManager
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.modelManager = modelManager
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
  }

  func start() async throws {
    guard !isRunning, !isStopping else {
      throw TranscriptionManagerError.liveSessionAlreadyRunning
    }
    guard await permissionsManager.ensureGranted(.microphone).isGranted else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }
    if let language = currentLanguage,
      !language.lowercased().hasPrefix("en") {
      throw FluidAudioModelError.unsupportedLanguage(language)
    }

    let transcriber = try await modelManager.makeReadyManager()
    await transcriber.reset()

    let transcriptPump = FluidAudioTranscriptPump()
    transcriptPump.start { [weak self] event in
      await self?.handleTranscriptEvent(event)
    }
    self.transcriptPump = transcriptPump
    await configureCallbacks(for: transcriber, transcriptPump: transcriptPump)

    latestText = ""
    processingError = nil
    self.transcriber = transcriber

    let pump = FluidAudioBufferPump()
    pump.start(manager: transcriber) { [weak self] error in
      Task { @MainActor [weak self] in
        self?.handleProcessingError(error)
      }
    }
    audioPump = pump

    let session = await audioDeviceManager.beginUsingPreferredInput()
    activeInputSession = session
    audioEngine = AVAudioEngine()

    do {
      let inputNode = audioEngine.inputNode
      inputNode.removeTap(onBus: 0)
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard audioInputFormatIsUsable(inputFormat) else {
        throw TranscriptionManagerError.noUsableAudioInput
      }
      inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak pump] buffer, _ in
        pump?.enqueue(buffer)
      }
      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      streamingStartTime = Date()
      isRunning = true
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning, !isStopping else { return }
    isStopping = true
    isRunning = false

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    let droppedBuffers = await audioPump?.finish() ?? 0
    reportDroppedBuffers(droppedBuffers)
    audioPump = nil

    if processingError == nil {
      await applyLiveStopGrace(appSettings.liveStopGracePeriod)
    }

    let result = await finishTranscription()

    if let transcriber {
      await transcriber.reset()
    }
    self.transcriber = nil
    await transcriptPump?.finish()
    transcriptPump = nil
    await endActiveInputSession()

    let duration = streamingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    streamingStartTime = nil
    isStopping = false

    switch result {
    case .success(let finalText):
      let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? latestText
        : finalText
      let transcription = TranscriptionResult(
        text: text,
        segments: [],
        confidence: nil,
        duration: duration,
        modelIdentifier: currentModel,
        cost: nil,
        rawPayload: nil,
        debugInfo: nil
      )
      delegate?.liveTranscriber(self, didFinishWith: transcription)
    case .failure(let error):
      if processingError == nil {
        delegate?.liveTranscriber(self, didFail: error)
      }
    }
  }

  private func configureCallbacks(
    for transcriber: StreamingEouAsrManager,
    transcriptPump: FluidAudioTranscriptPump
  ) async {
    await transcriber.setPartialTranscriptCallback { [weak transcriptPump] text in
      transcriptPump?.enqueue(.partial(text))
    }
    await transcriber.setEouCallback { [weak transcriptPump] utterance in
      transcriptPump?.enqueue(.utteranceBoundary(utterance))
    }
  }

  private func handleTranscriptEvent(_ event: FluidAudioTranscriptEvent) {
    switch event {
    case .partial(let text):
      latestText = text
      delegate?.liveTranscriber(self, didUpdatePartial: text)
    case .utteranceBoundary(let utterance):
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: utterance)
    }
  }

  private func finishTranscription() async -> Result<String, Error> {
    if let processingError {
      return .failure(processingError)
    }
    guard let transcriber else {
      return .failure(FluidAudioModelError.notInstalled)
    }
    do {
      return .success(try await transcriber.finish())
    } catch {
      return .failure(error)
    }
  }

  private func handleProcessingError(_ error: Error) {
    guard processingError == nil else { return }
    processingError = error
    delegate?.liveTranscriber(self, didFail: error)
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    let droppedBuffers = await audioPump?.finish() ?? 0
    reportDroppedBuffers(droppedBuffers)
    audioPump = nil
    if let transcriber {
      await transcriber.reset()
    }
    transcriber = nil
    await transcriptPump?.finish()
    transcriptPump = nil
    await endActiveInputSession()
    isRunning = false
    isStopping = false
    streamingStartTime = nil
  }

  private func reportDroppedBuffers(_ count: Int) {
    guard count > 0 else { return }
    logger.warning("Dropped \(count, privacy: .public) FluidAudio input buffers while processing lagged")
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}

private enum FluidAudioTranscriptEvent: Sendable {
  case partial(String)
  case utteranceBoundary(String)
}

private final class FluidAudioTranscriptPump: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<FluidAudioTranscriptEvent>.Continuation?
  private var consumerTask: Task<Void, Never>?

  func start(onEvent: @escaping @Sendable (FluidAudioTranscriptEvent) async -> Void) {
    let pair = AsyncStream<FluidAudioTranscriptEvent>.makeStream(bufferingPolicy: .unbounded)
    lock.lock()
    continuation = pair.continuation
    lock.unlock()
    consumerTask = Task {
      for await event in pair.stream {
        await onEvent(event)
      }
    }
  }

  func enqueue(_ event: FluidAudioTranscriptEvent) {
    lock.lock()
    let continuation = continuation
    lock.unlock()
    continuation?.yield(event)
  }

  func finish() async {
    let continuation = takeContinuation()
    continuation?.finish()
    await consumerTask?.value
    consumerTask = nil
  }

  private func takeContinuation() -> AsyncStream<FluidAudioTranscriptEvent>.Continuation? {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    return continuation
  }
}

private final class FluidAudioBufferPump: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  private var consumerTask: Task<Void, Never>?
  private var failed = false
  private var droppedBufferCount = 0

  func start(
    manager: StreamingEouAsrManager,
    onError: @escaping @Sendable (Error) -> Void
  ) {
    let pair = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(32))
    lock.lock()
    continuation = pair.continuation
    failed = false
    droppedBufferCount = 0
    lock.unlock()

    consumerTask = Task {
      do {
        for await buffer in pair.stream {
          _ = try await manager.process(audioBuffer: buffer)
        }
      } catch {
        let continuation = markFailed()
        continuation?.finish()
        onError(error)
      }
    }
  }

  func enqueue(_ buffer: AVAudioPCMBuffer) {
    guard let copiedBuffer = Self.copy(buffer) else { return }
    lock.lock()
    let continuation = failed ? nil : continuation
    lock.unlock()
    guard let continuation else { return }
    if case .dropped = continuation.yield(copiedBuffer) {
      lock.lock()
      droppedBufferCount += 1
      lock.unlock()
    }
  }

  func finish() async -> Int {
    let continuation = takeContinuation()
    continuation?.finish()
    await consumerTask?.value
    consumerTask = nil
    return currentDroppedBufferCount()
  }

  private func markFailed() -> AsyncStream<AVAudioPCMBuffer>.Continuation? {
    lock.lock()
    failed = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    return continuation
  }

  private func takeContinuation() -> AsyncStream<AVAudioPCMBuffer>.Continuation? {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    return continuation
  }

  private func currentDroppedBufferCount() -> Int {
    lock.lock()
    let count = droppedBufferCount
    lock.unlock()
    return count
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let frameLength = buffer.frameLength
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameLength) else {
      return nil
    }
    copy.frameLength = frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
    for index in 0..<min(source.count, destination.count) {
      guard let sourceData = source[index].mData, let destinationData = destination[index].mData else {
        continue
      }
      let copiedByteCount = min(
        Int(source[index].mDataByteSize),
        Int(destination[index].mDataByteSize)
      )
      destinationData.copyMemory(
        from: sourceData,
        byteCount: copiedByteCount
      )
      destination[index].mDataByteSize = UInt32(copiedByteCount)
    }
    return copy
  }
}
