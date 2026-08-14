import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import Speech
import os.log

private let logger = SpeakLogger.logger(category: "NativeOSXLiveTranscriber")

protocol NativeSpeechRecognitionTask: AnyObject {
  func cancel()
}

extension SFSpeechRecognitionTask: NativeSpeechRecognitionTask {}

struct NativeSpeechRecognitionResult {
  let text: String
  let segments: [TranscriptionSegment]
  let confidence: Double?
  let isFinal: Bool

  init(text: String, segments: [TranscriptionSegment] = [], confidence: Double? = nil, isFinal: Bool) {
    self.text = text
    self.segments = segments
    self.confidence = confidence
    self.isFinal = isFinal
  }

  init(_ result: SFSpeechRecognitionResult) {
    self.text = result.bestTranscription.formattedString
    self.segments = result.bestTranscription.segments.map { segment in
      TranscriptionSegment(
        startTime: segment.timestamp,
        endTime: segment.timestamp + segment.duration,
        text: segment.substring,
        isFinal: result.isFinal,
        confidence: Double(segment.confidence)
      )
    }
    self.confidence = result.transcriptionSegmentsConfidence
    self.isFinal = result.isFinal
  }
}

/// Owns the callback identity for one native recognition task at a time.
/// Tests inject task factories here so delayed callbacks exercise this exact
/// production guard without microphone or speech-recognition permissions.
@MainActor
final class NativeSpeechRecognitionTaskLifecycle {
  typealias Callback = (NativeSpeechRecognitionResult?, Error?) -> Void
  typealias Factory = (@escaping Callback) -> any NativeSpeechRecognitionTask

  private var activeRun: LiveTranscriptionRun.Token?
  private var task: (any NativeSpeechRecognitionTask)?

  func start(factory: Factory, onEvent: @escaping Callback) {
    retire()
    let run = LiveTranscriptionRun.Token()
    activeRun = run
    task = factory { [weak self, weak run] result, error in
      Task { @MainActor [weak self, weak run] in
        guard let self,
          LiveTranscriptionRun.isCurrent(run, activeStream: self.activeRun)
        else { return }
        onEvent(result, error)
      }
    }
  }

  func retire() {
    activeRun = nil
    task?.cancel()
    task = nil
  }
}

final class NativeOSXLiveTranscriber: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings
  private let audioDeviceManager: AudioInputDeviceManager
  private var speechRecognizer: SFSpeechRecognizer?
  private var audioEngine = AVAudioEngine()
  private let recognitionTaskLifecycle = NativeSpeechRecognitionTaskLifecycle()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var currentLocaleIdentifier: String?
  private var currentModel: String?
  private var latestResult: NativeSpeechRecognitionResult?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  /// Guards against calling finish() more than once per session.
  private var hasFinished: Bool = false
  /// Accumulated text from recognition segments finalised mid-session (on pause).
  private var committedText: String = ""
  /// Last `formattedString` received from the recognizer, used to detect
  /// implicit text resets where Apple silently clears the transcript.
  private var lastFormattedString: String = ""

  init(
    permissionsManager: PermissionsManager,
    appSettings: AppSettings,
    audioDeviceManager: AudioInputDeviceManager
  ) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
    self.audioDeviceManager = audioDeviceManager
  }

  func configure(language: String?, model: String) {
    currentLocaleIdentifier = language
    currentModel = model
  }

  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.permissionsMissing
    }

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()

    // Bind a fresh engine to the now-selected default input device. Reusing a
    // long-lived engine across device changes leaves it pointing at a stale HAL
    // device and `start()` then fails with kAudioHardwareBadDeviceError.
    audioEngine = AVAudioEngine()

    let localeIdentifier = currentLocaleIdentifier ?? appSettings.resolvedPreferredLocaleIdentifier

    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw TranscriptionManagerError.recognizerUnavailable
    }
    speechRecognizer = recognizer

    request = makeRecognitionRequest(for: recognizer)

    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let format = inputNode.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(format) else {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw TranscriptionManagerError.noUsableAudioInput
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.request?.append(buffer)
    }

    do {
      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
    } catch {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw error
    }

    latestResult = nil
    hasFinished = false
    committedText = ""
    lastFormattedString = ""
    guard request != nil else {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw TranscriptionManagerError.recognizerUnavailable
    }
    await MainActor.run {
      // Publish session state before starting recognition so final/error
      // callbacks (all main-actor ordered) observe a fully started session.
      self.activeInputSession = sessionContext
      self.isRunning = true
      self.startRecognitionTask(with: recognizer)
    }
  }

  func stop() async {
    guard isRunning else { return }
    // Retire the run before teardown: cancel() can still deliver queued events.
    let finishingRequest = await MainActor.run { () -> SFSpeechAudioBufferRecognitionRequest? in
      let pending = self.request
      self.request = nil
      self.recognitionTaskLifecycle.retire()
      return pending
    }
    finishingRequest?.endAudio()
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    // Always ensure the delegate is called so the continuation in
    // TranscriptionManager is resumed.  If a recognition callback Task
    // already dispatched finish(), the hasFinished guard prevents a
    // double-resume.
    await MainActor.run {
      guard !self.hasFinished else { return }
      if let result = self.latestResult {
        self.finish(with: result)
      } else if !self.committedText.isEmpty {
        // No latest result but we have committed text from finalised segments.
        self.hasFinished = true
        let outcome = TranscriptionResult(
          text: self.committedText,
          segments: [],
          confidence: nil,
          duration: 0,
          modelIdentifier: self.currentModel ?? AppleLocalModels.legacySpeechModelID,
          cost: nil,
          rawPayload: nil,
          debugInfo: nil
        )
        self.delegate?.liveTranscriber(self, didFinishWith: outcome)
      } else {
        // No results received (e.g. very short recording / silence).
        // Synthesise an empty result so the continuation isn't orphaned.
        self.hasFinished = true
        let empty = TranscriptionResult(
          text: "",
          segments: [],
          confidence: nil,
          duration: 0,
          modelIdentifier: self.currentModel ?? AppleLocalModels.legacySpeechModelID,
          cost: nil,
          rawPayload: nil,
          debugInfo: nil
        )
        self.delegate?.liveTranscriber(self, didFinishWith: empty)
      }
    }

    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func finish(with result: NativeSpeechRecognitionResult) {
    // Guard against double finish - can happen if recognition callback delivers
    // a final result at the same time stop() is called
    guard !hasFinished else { return }
    hasFinished = true

    let segments = result.segments
    let currentText = result.text
    let fullText = [committedText, currentText].filter { !$0.isEmpty }.joined(separator: " ")
    let duration = (segments.last?.endTime ?? 0) - (segments.first?.startTime ?? 0)
    let outcome = TranscriptionResult(
      text: fullText,
      segments: segments,
      confidence: result.confidence,
      duration: duration,
      modelIdentifier: currentModel ?? AppleLocalModels.legacySpeechModelID,
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )

    delegate?.liveTranscriber(self, didFinishWith: outcome)
  }

  // MARK: - Recognition task lifecycle

  /// Creates and starts a recognition task, routing results through the
  /// accumulation logic so that mid-session `isFinal` events commit text
  /// rather than clearing it.
  @MainActor
  private func startRecognitionTask(with recognizer: SFSpeechRecognizer) {
    guard let activeRequest = request else { return }
    recognitionTaskLifecycle.start(
      factory: { callback in
        recognizer.recognitionTask(with: activeRequest) { result, error in
          callback(result.map { NativeSpeechRecognitionResult($0) }, error)
        }
      },
      onEvent: { [weak self] result, error in
        guard let self else { return }
        if let result {
          self.latestResult = result
          let currentText = result.text
          self.commitIfImplicitReset(currentText: currentText, isFinal: result.isFinal)
          self.lastFormattedString = currentText

          let displayText = [self.committedText, currentText]
            .filter { !$0.isEmpty }.joined(separator: " ")
          let update = LiveTranscriptionUpdate(
            text: displayText,
            isFinal: false,
            confidence: result.confidence
          )
          self.delegate?.liveTranscriber(self, didUpdateWith: update)
          self.delegate?.liveTranscriber(self, didUpdatePartial: displayText)
          if result.isFinal {
            logger.info("Mid-session isFinal – committing \(displayText.count) chars, restarting")
            self.committedText = displayText
            self.lastFormattedString = ""
            self.restartRecognitionTask()
          }
        } else if let error {
          self.delegate?.liveTranscriber(self, didFail: error)
          self.endInputSessionAfterRecognitionError()
        }
      }
    )
  }

  @MainActor
  private func endInputSessionAfterRecognitionError() {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    Task { @MainActor [audioDeviceManager] in
      await audioDeviceManager.endUsingPreferredInput(session: session)
    }
  }

  /// Detect when Apple's recognizer silently resets `formattedString` after
  /// a pause without sending `isFinal`.  If the new text is dramatically
  /// shorter than the previous result, commit the old text to prevent loss.
  @MainActor
  private func commitIfImplicitReset(currentText: String, isFinal: Bool) {
    guard !isFinal,
      lastFormattedString.count >= 10,
      currentText.count < lastFormattedString.count / 2
    else { return }
    logger.info("Implicit text reset – committing \(self.lastFormattedString.count) chars")
    committedText = [committedText, lastFormattedString]
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// Restart recognition after a mid-session `isFinal` so continued speech
  /// is captured without losing previously committed text.
  @MainActor
  private func restartRecognitionTask() {
    guard isRunning, let recognizer = speechRecognizer else { return }

    recognitionTaskLifecycle.retire()

    // Minting the replacement request retires the previous run's identity, so
    // anything the cancelled task still delivers is dropped by the guard in
    // `startRecognitionTask(with:)`.
    request = makeRecognitionRequest(for: recognizer)
    latestResult = nil
    lastFormattedString = ""

    startRecognitionTask(with: recognizer)
  }

  private func makeRecognitionRequest(for recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    return request
  }

  private func ensurePermissions() async -> Bool {
    let microphone = await permissionsManager.ensureGranted(.microphone)
    let speech = await permissionsManager.ensureGranted(.speechRecognition)
    return microphone.isGranted && speech.isGranted
  }
}

final class UnsupportedLocalLiveTranscriber: LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  func configure(language: String?, model: String) {}

  func start() async throws {
    throw TranscriptionManagerError.localLiveStreamingUnsupported
  }

  func stop() async {
    isRunning = false
  }
}

extension SFSpeechRecognitionResult {
  fileprivate var transcriptionSegmentsConfidence: Double? {
    guard !bestTranscription.segments.isEmpty else { return nil }
    let confidences = bestTranscription.segments.map { Double($0.confidence) }
    let total = confidences.reduce(0, +)
    return total / Double(confidences.count)
  }
}
