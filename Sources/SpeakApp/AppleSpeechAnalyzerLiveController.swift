import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import Speech
import os.log

final class AppleSpeechAnalyzerLiveController: LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning = false

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings
  private let audioDeviceManager: AudioInputDeviceManager
  private var audioEngine = AVAudioEngine()
  private var analyzerSession: Any?
  /// Identity of the analyzer run currently allowed to publish transcript text.
  /// See `LiveTranscriptionRun.Token`: the update handler is an argument to the
  /// session's initialiser, so it cannot capture the session it belongs to.
  private var activeRun: LiveTranscriptionRun.Token?
  private var audioConverter: Any?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var currentLanguage: String?
  private var currentModel: String = AppleLocalModels.speechTranscriberModelID
  private var latestUpdate = LiveTranscriptionUpdate(text: "")

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
    currentLanguage = language
    if AppleLocalModels.isSpeechAnalyzerModel(model) {
      currentModel = model
    }
  }

  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.permissionsMissing
    }
    guard #available(macOS 26.0, *) else {
      throw AppleLocalModelError.speechTranscriberUnavailable
    }

    let inputSession = await audioDeviceManager.beginUsingPreferredInput()
    audioEngine = AVAudioEngine()
    do {
      try await startSpeechAnalyzer()
      activeInputSession = inputSession
      latestUpdate = LiveTranscriptionUpdate(text: "")
      isRunning = true
    } catch {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
      await audioDeviceManager.endUsingPreferredInput(session: inputSession)
      throw error
    }
  }

  @available(macOS 26.0, *)
  private func startSpeechAnalyzer() async throws {
    // Published before the session exists so the handler can never observe a
    // window in which this run is not yet the active one. The handler hops to
    // the main actor through an unstructured Task, so an update produced by the
    // previous recording can land after `stop()` has returned — and this
    // controller instance is reused across recordings, so it would repaint the
    // next recording's transcript (issue #668).
    let run = LiveTranscriptionRun.Token()
    activeRun = run

    let session = try await AppleSpeechAnalyzerLiveSession(
      localeIdentifier: currentLanguage ?? appSettings.resolvedPreferredLocaleIdentifier,
      engine: AppleSpeechAnalyzerEngine(modelID: currentModel)
    ) { [weak self, weak run] update in
      Task { @MainActor [weak self, weak run] in
        guard let self,
          LiveTranscriptionRun.isCurrent(run, activeStream: self.activeRun)
        else { return }
        self.latestUpdate = LiveTranscriptionUpdate(
          text: update.text,
          isFinal: update.isFinal,
          confidence: update.confidence
        )
        self.delegate?.liveTranscriber(self, didUpdateWith: self.latestUpdate)
        self.delegate?.liveTranscriber(self, didUpdatePartial: update.text)
      }
    }

    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(inputFormat) else {
      activeRun = nil
      await session.cancel()
      throw TranscriptionManagerError.noUsableAudioInput
    }
    do {
      let converter = try AppleSpeechAudioConverter(
        sourceFormat: inputFormat,
        targetFormat: session.audioFormat
      )
      inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
        guard let converted = converter.convert(buffer) else { return }
        session.send(converted)
      }
      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      analyzerSession = session
      audioConverter = converter
    } catch {
      activeRun = nil
      audioEngine.stop()
      inputNode.removeTap(onBus: 0)
      await session.cancel()
      throw error
    }
  }

  func stop() async {
    guard isRunning else { return }
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    // Retired after `finish()` so a final flush the analyzer emits through the
    // update handler still counts towards this recording's result.
    defer {
      activeRun = nil
      analyzerSession = nil
      audioConverter = nil
    }

    if #available(macOS 26.0, *),
      let session = analyzerSession as? AppleSpeechAnalyzerLiveSession {
      do {
        let result = try await session.finish()
        delegate?.liveTranscriber(self, didFinishWith: result)
      } catch {
        delegate?.liveTranscriber(self, didFail: error)
      }
    } else {
      delegate?.liveTranscriber(
        self,
        didFinishWith: TranscriptionResult(
          text: latestUpdate.text,
          segments: [],
          confidence: latestUpdate.confidence,
          duration: 0,
          modelIdentifier: currentModel,
          cost: nil,
          rawPayload: nil,
          debugInfo: nil
        )
      )
    }

    await endActiveInputSession()
  }

  private func ensurePermissions() async -> Bool {
    let microphone = await permissionsManager.ensureGranted(.microphone)
    let speech = await permissionsManager.ensureGranted(.speechRecognition)
    return microphone.isGranted && speech.isGranted
  }

  private func endActiveInputSession() async {
    guard let activeInputSession else { return }
    self.activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: activeInputSession)
  }
}
