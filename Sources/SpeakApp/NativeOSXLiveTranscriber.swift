import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import Speech
import os.log

final class NativeOSXLiveTranscriber: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings
  private let audioDeviceManager: AudioInputDeviceManager
  private var speechRecognizer: SFSpeechRecognizer?
  private var audioEngine = AVAudioEngine()
  private var recognitionTask: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var currentLocaleIdentifier: String?
  private var currentModel: String?
  private var latestResult: SFSpeechRecognitionResult?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  /// Guards against calling finish() more than once per session.
  private var hasFinished: Bool = false
  /// Accumulated text from recognition segments finalised mid-session (on pause).
  private var committedText: String = ""
  /// Last `formattedString` received from the recognizer, used to detect
  /// implicit text resets where Apple silently clears the transcript.
  private var lastFormattedString: String = ""
  /// Monotonic counter incremented on each recognition restart so that
  /// error callbacks from cancelled tasks are ignored.
  private var recognitionGeneration: Int = 0

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

    let localeIdentifier = currentLocaleIdentifier ?? appSettings.preferredLocaleIdentifier

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
    // Monotonically increase so late callbacks from a previous session can never
    // match the generation of this one. Resetting to 0 would let a stale task
    // whose generation happened to be 0 be treated as current.
    recognitionGeneration += 1
    guard request != nil else {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw TranscriptionManagerError.recognizerUnavailable
    }
    startRecognitionTask(with: recognizer)

    activeInputSession = sessionContext
    isRunning = true
  }

  func stop() async {
    guard isRunning else { return }
    request?.endAudio()
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionTask?.cancel()
    request = nil
    recognitionTask = nil
    isRunning = false

    // Always ensure the delegate is called so the continuation in
    // TranscriptionManager is resumed.  If a recognition callback Task
    // already dispatched finish(), the hasFinished guard prevents a
    // double-resume.
    // Bump generation to suppress error callbacks from the cancelled task.
    recognitionGeneration += 1
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

  private func finish(with result: SFSpeechRecognitionResult) {
    // Guard against double finish - can happen if recognition callback delivers
    // a final result at the same time stop() is called
    guard !hasFinished else { return }
    hasFinished = true

    Task { await self.endActiveInputSession() }

    let segments = result.bestTranscription.segments.map { segment in
      TranscriptionSegment(
        startTime: segment.timestamp,
        endTime: segment.timestamp + segment.duration,
        text: segment.substring,
        isFinal: result.isFinal,
        confidence: Double(segment.confidence)
      )
    }

    let currentText = result.bestTranscription.formattedString
    let fullText = [committedText, currentText].filter { !$0.isEmpty }.joined(separator: " ")
    let duration = (segments.last?.endTime ?? 0) - (segments.first?.startTime ?? 0)
    let outcome = TranscriptionResult(
      text: fullText,
      segments: segments,
      confidence: result.bestTranscription.segments.isEmpty
        ? nil
        : result
          .transcriptionSegmentsConfidence,
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
  private func startRecognitionTask(with recognizer: SFSpeechRecognizer) {
    let generation = recognitionGeneration
    guard let activeRequest = request else { return }
    recognitionTask = recognizer.recognitionTask(with: activeRequest) { [weak self] result, error in
      guard let self else { return }
      if let result {
        Task { @MainActor [weak self] in
          guard let self, generation == self.recognitionGeneration else { return }
          self.latestResult = result
          let currentText = result.bestTranscription.formattedString
          self.commitIfImplicitReset(currentText: currentText, isFinal: result.isFinal)
          self.lastFormattedString = currentText

          let displayText = [self.committedText, currentText]
            .filter { !$0.isEmpty }.joined(separator: " ")
          let confidence = result.bestTranscription.segments.isEmpty
            ? nil
            : result.transcriptionSegmentsConfidence
          let update = LiveTranscriptionUpdate(
            text: displayText,
            isFinal: false,
            confidence: confidence
          )
          self.delegate?.liveTranscriber(self, didUpdateWith: update)
          self.delegate?.liveTranscriber(self, didUpdatePartial: displayText)
          if result.isFinal {
            print(
              "[NativeOSXLiveTranscriber] Mid-session isFinal – "
                + "committing \(displayText.count) chars, restarting")
            self.committedText = displayText
            self.lastFormattedString = ""
            self.restartRecognitionTask()
          }
        }
      } else if let error {
        Task { @MainActor [weak self] in
          guard let self, generation == self.recognitionGeneration else { return }
          self.delegate?.liveTranscriber(self, didFail: error)
        }
        Task { [weak self] in
          guard let self else { return }
          let shouldEnd = await MainActor.run { generation == self.recognitionGeneration }
          if shouldEnd { await self.endActiveInputSession() }
        }
      }
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
    print(
      "[NativeOSXLiveTranscriber] Implicit text reset – "
        + "committing \(lastFormattedString.count) chars")
    committedText = [committedText, lastFormattedString]
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// Restart recognition after a mid-session `isFinal` so continued speech
  /// is captured without losing previously committed text.
  @MainActor
  private func restartRecognitionTask() {
    guard isRunning, let recognizer = speechRecognizer else { return }

    recognitionGeneration += 1
    recognitionTask?.cancel()
    recognitionTask = nil

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
