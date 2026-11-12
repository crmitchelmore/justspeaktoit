import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

#if !APP_STORE
@MainActor
// swiftlint:disable type_body_length
final class SherpaOnnxLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let runtimeManager: SherpaOnnxRuntimeManager
  private var audioEngine = AVAudioEngine()
  private let audioProcessor = SherpaOnnxAudioProcessor()
  private let targetSampleRate: Double = 16000
  private let logger = SpeakLogger.logger(category: "SherpaOnnxLiveController")

  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var currentModel: String?
  private var currentLanguage: String?
  /// The model the running sidecar loaded. Held for the whole session so a
  /// settings change mid-recording cannot retag the results of this one.
  private var activeModelID: String?
  private var streamingStartTime: Date?
  private var latestText: String = ""
  private var hasFinished: Bool = false
  /// Whether this run's sidecar delivered its `session_final` event — the
  /// proof that finalisation covered every accepted PCM frame (issue #679).
  private var receivedSessionFinal = false
  private var isStopping: Bool = false
  private var sidecarEvents = SherpaOnnxSidecarEventStream()
  /// Sink for the current process's stderr. Replaced on every start so stderr
  /// from a previous sidecar can never be attributed to this session.
  private var sidecarErrorSink: SherpaOnnxSidecarErrorSink?
  /// Set once `process.run()` succeeds; the pipes only reach EOF for a process
  /// that actually launched, so draining them is unsafe before this is true.
  private var processDidLaunch = false
  /// Cap on retained sidecar stderr so a chatty process cannot grow this without bound.
  private static let maxSidecarErrorByteCount = 8192

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    runtimeManager: SherpaOnnxRuntimeManager
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.runtimeManager = runtimeManager
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard !isRunning, !isStopping else {
      throw TranscriptionManagerError.liveSessionAlreadyRunning
    }
    guard await permissionsManager.ensureGranted(.microphone).isGranted else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let modelID = currentModel ?? appSettings.localStreamingModelSource
    activeModelID = modelID
    let bundle = try await runtimeManager.ensureReady(sourceID: modelID)
    let process = try makeProcess(bundle: bundle)
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }

    latestText = ""
    hasFinished = false
    receivedSessionFinal = false
    sidecarEvents = SherpaOnnxSidecarEventStream()
    processDidLaunch = false
    let errorSink = SherpaOnnxSidecarErrorSink(maxByteCount: Self.maxSidecarErrorByteCount)
    sidecarErrorSink = errorSink
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe

    // `stdoutPipe` is this run's identity. The handler runs on a pipe queue and
    // hops to the main actor, so a Task it spawned can still land after the
    // sidecar is torn down — and this controller is reused across recordings,
    // so that stale output would repaint the next recording's transcript.
    // `hasFinished` cannot catch it: `start()` resets it to false (issue #668).
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak stdoutPipe] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor [weak self, weak stdoutPipe] in
        guard let self,
          LiveTranscriptionRun.isCurrent(stdoutPipe, activeStream: self.stdoutPipe)
        else { return }
        self.handleSidecarOutput(data)
      }
    }

    // Drain stderr continuously: an undrained pipe fills its kernel buffer and
    // blocks the sidecar's next write, which would stall transcription entirely.
    // The append is synchronous and capped, so a burst of stderr neither spawns
    // a task per read nor grows memory; the sink is captured by value so bytes
    // always land in the session they were produced for.
    stderrPipe.fileHandleForReading.readabilityHandler = { [errorSink] handle in
      errorSink.append(handle.availableData)
    }

    do {
      try process.run()
      processDidLaunch = true
    } catch {
      // The pipes, handlers and `process` are already stored on self; without
      // this the failed launch would leave them attached to the next start.
      await cleanupAfterFailedStart()
      throw error
    }

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()
    activeInputSession = sessionContext
    audioEngine = LiveInputEngines.shared.makeEngine()

    do {
      let inputNode = audioEngine.inputNode
      inputNode.removeTap(onBus: 0)
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard audioInputFormatIsUsable(inputFormat) else {
        throw TranscriptionManagerError.noUsableAudioInput
      }
      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      ) else {
        throw SherpaOnnxRuntimeError.processFailed("Could not create 16 kHz Float32 audio format.")
      }
      let writer = stdinPipe.fileHandleForWriting
      audioProcessor.setRunning(true)
      let processor = audioProcessor
      let log = logger
      try inputNode.installTapSafely(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
        processor.handleAudioTap(
          buffer,
          inputFormat: inputFormat,
          outputFormat: outputFormat,
          writer: writer,
          logger: log
        )
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
    guard isRunning else { return }
    isStopping = true
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    if let writer = stdinPipe?.fileHandleForWriting {
      audioProcessor.drainConverterTail(to: writer, logger: logger)
    }
    audioProcessor.setRunning(false)

    await applyLiveStopGrace(appSettings.liveStopGracePeriod)
    try? stdinPipe?.fileHandleForWriting.close()
    await waitForProcessExit()
    drainRemainingSidecarPipes()
    processRemainingSidecarOutput()
    logSidecarErrorOutput()
    isRunning = false

    let duration = streamingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    hasFinished = true
    if receivedSessionFinal {
      let result = TranscriptionResult(
        text: latestText,
        segments: latestText.isEmpty ? [] : [
          TranscriptionSegment(startTime: 0, endTime: duration, text: latestText)
        ],
        confidence: nil,
        duration: duration,
        modelIdentifier: currentModel ?? appSettings.localStreamingModelSource,
        cost: nil,
        rawPayload: nil,
        debugInfo: nil
      )
      delegate?.liveTranscriber(self, didFinishWith: result)
    } else {
      // The sidecar never delivered its whole-session final: forced
      // termination or a crash must surface as an explicit failure, never as
      // a success carrying a stale partial that silently drops trailing
      // speech (issue #679).
      delegate?.liveTranscriber(
        self,
        didFail: SherpaOnnxRuntimeError.processFailed(
          "Local finalisation did not complete; the transcript may be missing "
            + "trailing speech. The live text shown so far was kept."
        )
      )
    }
    await endActiveInputSession()
    resetProcessState()
    isStopping = false
  }

  private func makeProcess(bundle: SherpaOnnxModelBundle) throws -> Process {
    let process = Process()
    process.executableURL = try runtimeManager.pythonExecutable()
    process.arguments = [
      "-u",
      try runtimeManager.sidecarScriptURL().path,
      "--tokens", bundle.tokens.path,
      "--encoder", bundle.encoder.path,
      "--decoder", bundle.decoder.path,
      "--joiner", bundle.joiner.path,
      "--feature-dim", "\(bundle.featureDim)",
      "--model-type", bundle.modelType
    ] + Self.languageArguments(for: bundle, language: currentLanguage)
    return process
  }

  /// Only language-ID prompted models get a prompt, and only for an explicit
  /// supported choice: a wrong forced language can suppress the transcript.
  nonisolated static func languageArguments(for bundle: SherpaOnnxModelBundle, language: String?) -> [String] {
    guard bundle.supportsLanguageHint,
      let hint = NemotronLocalModels.languageHint(forLocaleIdentifier: language)
    else { return [] }
    return ["--language", hint]
  }

  private func handleSidecarOutput(_ data: Data) {
    guard !hasFinished else { return }
    for event in sidecarEvents.append(data) {
      handleSidecarEvent(event)
    }
  }

  private func logSidecarErrorOutput() {
    guard let captured = sidecarErrorSink?.drainText()
      .trimmingCharacters(in: .whitespacesAndNewlines), !captured.isEmpty
    else { return }
    logger.error("sherpa-onnx sidecar stderr: \(captured, privacy: .public)")
  }

  /// Detaches the readability handlers and picks up whatever the sidecar left in
  /// the pipes. `resetProcessState()` drops the pipes straight after, so bytes
  /// still sitting in the kernel buffer when the process exited would otherwise
  /// never reach the logs. Only reads once the process has actually exited:
  /// `availableData` blocks while a writer is still attached to the pipe.
  private func drainRemainingSidecarPipes() {
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    guard processDidLaunch, process?.isRunning == false else { return }
    if let stdout = stdoutPipe?.fileHandleForReading {
      for chunk in SherpaOnnxSidecarPipe.remainingData(on: stdout) {
        handleSidecarOutput(chunk)
      }
    }
    if let stderr = stderrPipe?.fileHandleForReading, let sink = sidecarErrorSink {
      for chunk in SherpaOnnxSidecarPipe.remainingData(on: stderr) {
        sink.append(chunk)
      }
    }
  }

  private func processRemainingSidecarOutput() {
    guard let event = sidecarEvents.flush() else { return }
    handleSidecarEvent(event)
  }

  private func handleSidecarEvent(_ event: SherpaOnnxSidecarEvent) {
    guard !hasFinished else { return }
    switch event.type {
    case "partial", "session_final":
      if event.type == "session_final" { receivedSessionFinal = true }
      guard let rawText = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !rawText.isEmpty else {
        return
      }
      let text = SherpaOnnxTranscriptNormalizer.normalize(rawText, modelID: activeModelID)
      latestText = text
      let update = LiveTranscriptionUpdate(text: text, isFinal: event.type == "session_final")
      delegate?.liveTranscriber(self, didUpdateWith: update)
      delegate?.liveTranscriber(self, didUpdatePartial: text)
    case "error":
      delegate?.liveTranscriber(
        self,
        didFail: SherpaOnnxRuntimeError.processFailed(event.message ?? "Unknown sherpa-onnx error.")
      )
    default:
      break
    }
  }

  private func waitForProcessExit() async {
    guard let process else { return }
    // Offline transducer models (Parakeet TDT) decode the whole session once
    // stdin closes, so the exit allowance must scale with what was recorded —
    // a fixed window silently truncated long sessions to a stale partial
    // (issue #679).
    let sessionSeconds = streamingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    let deadline = Date().addingTimeInterval(
      Self.finalisationAllowance(forSessionSeconds: sessionSeconds)
    )
    while process.isRunning && Date() < deadline && !receivedSessionFinal {
      try? await Task.sleep(for: .milliseconds(100))
    }
    // Give a process that already produced its final a moment to exit.
    for _ in 0..<20 where process.isRunning {
      try? await Task.sleep(for: .milliseconds(100))
    }
    if process.isRunning {
      process.terminate()
    }
  }

  /// How long finalisation may run after stdin closes: at the measured
  /// real-time factor (~0.04) a quarter of the session duration is six-fold
  /// headroom, floored at the historical ten seconds for short sessions.
  nonisolated static func finalisationAllowance(
    forSessionSeconds seconds: TimeInterval
  ) -> TimeInterval {
    max(10, seconds * 0.25)
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    audioProcessor.setRunning(false)
    try? stdinPipe?.fileHandleForWriting.close()
    // `terminate()` raises on a process that never launched, which is exactly
    // the case when `process.run()` itself is what failed.
    if let process, process.isRunning {
      process.terminate()
    }
    drainRemainingSidecarPipes()
    logSidecarErrorOutput()
    isRunning = false
    isStopping = false
    await endActiveInputSession()
    resetProcessState()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func resetProcessState() {
    process = nil
    processDidLaunch = false
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
    streamingStartTime = nil
    sidecarEvents = SherpaOnnxSidecarEventStream()
    sidecarErrorSink = nil
  }
}
// swiftlint:enable type_body_length
#endif
