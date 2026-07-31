#if !APP_STORE
@preconcurrency import AVFoundation
import FluidAudio
import Foundation
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
  private var transcriber: StreamingEouAsrManager?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var currentLanguage: String?
  private var currentModel = FluidAudioParakeetModel.id
  private var streamingStartTime: Date?
  private var latestText = ""
  private var processingError: Error?
  private var isStopping = false

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
    await configureCallbacks(for: transcriber)

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
    await audioPump?.finish()
    audioPump = nil

    if processingError == nil {
      await applyLiveStopGrace(appSettings.liveStopGracePeriod)
    }

    let result = await finishTranscription()

    if let transcriber {
      await transcriber.reset()
    }
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

  private func configureCallbacks(for transcriber: StreamingEouAsrManager) async {
    await transcriber.setPartialTranscriptCallback { [weak self] text in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.latestText = text
        self.delegate?.liveTranscriber(self, didUpdatePartial: text)
      }
    }
    await transcriber.setEouCallback { [weak self] utterance in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.delegate?.liveTranscriber(self, didDetectUtteranceBoundary: utterance)
      }
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
    await audioPump?.finish()
    audioPump = nil
    if let transcriber {
      await transcriber.reset()
    }
    await endActiveInputSession()
    isRunning = false
    isStopping = false
    streamingStartTime = nil
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}

private final class FluidAudioBufferPump: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  private var consumerTask: Task<Void, Never>?
  private var failed = false

  func start(
    manager: StreamingEouAsrManager,
    onError: @escaping @Sendable (Error) -> Void
  ) {
    let pair = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
    lock.lock()
    continuation = pair.continuation
    failed = false
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
    continuation?.yield(copiedBuffer)
  }

  func finish() async {
    let continuation = takeContinuation()
    continuation?.finish()
    await consumerTask?.value
    consumerTask = nil
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
      destinationData.copyMemory(
        from: sourceData,
        byteCount: Int(source[index].mDataByteSize)
      )
      destination[index].mDataByteSize = source[index].mDataByteSize
    }
    return copy
  }
}
#endif
