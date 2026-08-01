import Foundation
import SpeakCore
import WhisperKit

@MainActor
final class WhisperKitLiveController: LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning = false

  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let modelManager: LocalModelManager
  private var transcriber: AudioStreamTranscriber?
  private var streamTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var startupContinuation: CheckedContinuation<Void, Error>?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var currentLanguage: String?
  private var currentModel = WhisperKitStreamingModel.prefix + "tiny"
  private var latestText = ""
  private var startedAt: Date?
  private var isStopping = false

  init(
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    modelManager: LocalModelManager
  ) {
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.modelManager = modelManager
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard !isRunning, streamTask == nil, !isStopping else {
      throw TranscriptionManagerError.liveSessionAlreadyRunning
    }
    guard await permissionsManager.ensureGranted(.microphone).isGranted else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }
    guard let batchModelID = WhisperKitStreamingModel.batchModelID(from: currentModel) else {
      throw TranscriptionManagerError.invalidLocalStreamingSource(currentModel)
    }

    let pipeline = try await modelManager.makeReadyPipeline(modelID: batchModelID)
    guard let tokenizer = pipeline.tokenizer else {
      throw TranscriptionManagerError.localLiveStreamingUnsupported
    }

    activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    latestText = ""
    startedAt = Date()

    let language = currentLanguage?
      .split(whereSeparator: { $0 == "_" || $0 == "-" })
      .first
      .map(String.init)
      .map { $0.lowercased() }
    let options = DecodingOptions(
      task: .transcribe,
      language: language,
      usePrefillPrompt: language != nil,
      skipSpecialTokens: true,
      wordTimestamps: true
    )
    let transcriber = AudioStreamTranscriber(
      audioEncoder: pipeline.audioEncoder,
      featureExtractor: pipeline.featureExtractor,
      segmentSeeker: pipeline.segmentSeeker,
      textDecoder: pipeline.textDecoder,
      tokenizer: tokenizer,
      audioProcessor: pipeline.audioProcessor,
      decodingOptions: options,
      stateChangeCallback: { [weak self] oldState, newState in
        guard oldState.currentText != newState.currentText
          || oldState.confirmedSegments != newState.confirmedSegments
          || oldState.unconfirmedSegments != newState.unconfirmedSegments
        else { return }
        Task { @MainActor [weak self] in
          self?.handleState(newState)
        }
      }
    )
    self.transcriber = transcriber

    try await withCheckedThrowingContinuation { continuation in
      startupContinuation = continuation
      streamTask = Task { [weak self, transcriber] in
        do {
          try await transcriber.startStreamTranscription()
          await self?.streamEnded(error: nil)
        } catch {
          await self?.streamEnded(error: error)
        }
      }
      startupTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        guard let self, let continuation = self.startupContinuation else { return }
        self.startupContinuation = nil
        self.isRunning = true
        continuation.resume()
      }
    }
  }

  func stop() async {
    guard isRunning || streamTask != nil else { return }
    isStopping = true
    startupTask?.cancel()
    startupTask = nil
    if let continuation = startupContinuation {
      startupContinuation = nil
      continuation.resume(throwing: TranscriptionManagerError.liveSessionNotRunning)
    }

    if let transcriber {
      await transcriber.stopStreamTranscription()
    }
    await streamTask?.value
    streamTask = nil
    transcriber = nil
    isRunning = false

    if let activeInputSession {
      await audioDeviceManager.endUsingPreferredInput(session: activeInputSession)
      self.activeInputSession = nil
    }

    let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
    startedAt = nil
    isStopping = false
    delegate?.liveTranscriber(
      self,
      didFinishWith: TranscriptionResult(
        text: latestText,
        segments: [],
        confidence: nil,
        duration: duration,
        modelIdentifier: currentModel,
        cost: nil,
        rawPayload: nil,
        debugInfo: nil
      )
    )
  }

  private func handleState(_ state: AudioStreamTranscriber.State) {
    let segmentText = (state.confirmedSegments + state.unconfirmedSegments)
      .map(\.text)
      .joined(separator: " ")
    let currentText = state.currentText == "Waiting for speech..." ? "" : state.currentText
    let text = clean([segmentText, currentText].joined(separator: " "))
    guard text != latestText else { return }
    latestText = text
    delegate?.liveTranscriber(self, didUpdatePartial: text)
  }

  private func streamEnded(error: Error?) async {
    startupTask?.cancel()
    startupTask = nil
    if let continuation = startupContinuation {
      startupContinuation = nil
      continuation.resume(throwing: error ?? TranscriptionManagerError.liveSessionNotRunning)
      await cleanupAfterFailedStart()
      return
    }
    guard !isStopping else { return }
    isRunning = false
    await cleanupInputSession()
    delegate?.liveTranscriber(
      self,
      didFail: error ?? TranscriptionManagerError.liveSessionNotRunning
    )
  }

  private func cleanupAfterFailedStart() async {
    streamTask = nil
    transcriber = nil
    startedAt = nil
    isRunning = false
    await cleanupInputSession()
  }

  private func cleanupInputSession() async {
    if let activeInputSession {
      await audioDeviceManager.endUsingPreferredInput(session: activeInputSession)
      self.activeInputSession = nil
    }
  }

  private func clean(_ text: String) -> String {
    text
      .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
