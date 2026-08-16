@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import OSLog
import SpeakCore

/// Live local streaming via FluidAudio's Parakeet EOU model.
///
/// Lifecycle is a run-identity state machine (mirroring the `activeRun`
/// pattern in `SwitchingLiveTranscriber`): every start mints a run ID before
/// any awaited work, every later allocation and callback requires that ID to
/// still be current, and stop retires the ID and awaits owned cleanup. This
/// guarantees a stop during suspended model preparation prevents microphone
/// activation, late callbacks from a retired run cannot affect a replacement,
/// and each run produces exactly one terminal delegate outcome (issue #715).
@MainActor
final class FluidAudioParakeetLiveController: LiveTranscriptionController {
  typealias TranscriberProvider = @MainActor () async throws -> any FluidAudioStreamingTranscribing
  typealias CaptureProvider = @MainActor () -> any FluidAudioAudioCapturing

  weak var delegate: LiveTranscriptionSessionDelegate?

  private enum Phase: Equatable {
    case idle
    case starting
    case running
    case stopping
  }

  var isRunning: Bool { phase == .running }

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let modelManager: FluidAudioModelManager
  private let transcriberProvider: TranscriberProvider?
  private let captureProvider: CaptureProvider

  private var phase: Phase = .idle
  private var runID: UUID?
  private var startTask: Task<Void, any Error>?
  private var capture: (any FluidAudioAudioCapturing)?
  private var audioPump: FluidAudioBufferPump?
  private var transcriptPump: FluidAudioTranscriptPump?
  private var transcriber: (any FluidAudioStreamingTranscribing)?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var currentLanguage: String?
  private var currentModel = FluidAudioParakeetModel.id
  private var streamingStartTime: Date?
  private var latestText = ""
  private var processingError: (any Error)?
  private var didDeliverFailure = false
  private let logger = SpeakLogger.logger(category: "FluidAudioLive")

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    modelManager: FluidAudioModelManager,
    transcriberProvider: TranscriberProvider? = nil,
    captureProvider: @escaping CaptureProvider = { FluidAudioEngineCapture() }
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.modelManager = modelManager
    self.transcriberProvider = transcriberProvider
    self.captureProvider = captureProvider
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
  }

  func start() async throws {
    guard phase == .idle else {
      throw TranscriptionManagerError.liveSessionAlreadyRunning
    }
    let run = UUID()
    runID = run
    phase = .starting
    latestText = ""
    processingError = nil
    didDeliverFailure = false

    // Startup runs in an owned task so a concurrent stop can cancel it and
    // await its unwinding before tearing down whatever it already allocated.
    let task = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      try await self.performStart(run: run)
    }
    startTask = task
    do {
      try await task.value
      if startTask == task { startTask = nil }
    } catch {
      if startTask == task { startTask = nil }
      // When phase is `.stopping` a concurrent stop owns the teardown; it is
      // already awaiting this task and cleans up once we unwind.
      if runID == run, phase == .starting {
        await teardownRunResources()
        retire(run)
      }
      throw error
    }
  }

  func stop() async {
    switch phase {
    case .idle, .stopping:
      return
    case .starting:
      guard let run = runID else { return }
      phase = .stopping
      let task = startTask
      startTask = nil
      task?.cancel()
      _ = try? await task?.value
      await teardownRunResources()
      retire(run)
    case .running:
      guard let run = runID else { return }
      await stopRunning(run)
    }
  }

  // MARK: - Startup

  private func performStart(run: UUID) async throws {
    guard await permissionsManager.ensureGranted(.microphone).isGranted else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }
    try ensureActive(run)
    if let language = currentLanguage,
      !language.lowercased().hasPrefix("en") {
      throw FluidAudioModelError.unsupportedLanguage(language)
    }

    // Each resource is published to `self` immediately upon acquisition so a
    // stop that cancelled this task can tear everything down after awaiting
    // our unwinding.
    let transcriber = try await makeTranscriber()
    self.transcriber = transcriber
    try ensureActive(run)
    await transcriber.resetSession()
    try ensureActive(run)

    let transcriptPump = FluidAudioTranscriptPump()
    transcriptPump.start { [weak self] event in
      await self?.handleTranscriptEvent(event, run: run)
    }
    self.transcriptPump = transcriptPump
    await transcriber.setPartialTranscriptHandler { [weak transcriptPump] text in
      transcriptPump?.enqueue(.partial(text))
    }
    await transcriber.setUtteranceHandler { [weak transcriptPump] utterance in
      transcriptPump?.enqueue(.utteranceBoundary(utterance))
    }
    try ensureActive(run)

    let pump = FluidAudioBufferPump()
    pump.start(
      process: { buffer in
        try await transcriber.streamAudio(buffer)
      },
      onError: { [weak self] error in
        Task { @MainActor [weak self] in
          self?.handleProcessingError(error, run: run)
        }
      }
    )
    audioPump = pump

    activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    try ensureActive(run)

    let capture = captureProvider()
    self.capture = capture
    try await capture.start { [weak pump] buffer in
      pump?.enqueue(buffer)
    }
    try ensureActive(run)
    streamingStartTime = Date()
    phase = .running
  }

  private func makeTranscriber() async throws -> any FluidAudioStreamingTranscribing {
    if let transcriberProvider {
      return try await transcriberProvider()
    }
    return try await modelManager.makeReadyManager()
  }

  /// Startup barrier: throws unless `run` is still the live starting run.
  private func ensureActive(_ run: UUID) throws {
    try Task.checkCancellation()
    guard runID == run, phase == .starting else {
      throw CancellationError()
    }
  }

  // MARK: - Stop

  private func stopRunning(_ run: UUID) async {
    phase = .stopping

    capture?.stop()
    capture = nil

    let pumpOutcome = await audioPump?.finish() ?? FluidAudioPumpOutcome()
    audioPump = nil
    logPressureDiagnostics(pumpOutcome)

    if pumpOutcome.processingError == nil, processingError == nil {
      await applyLiveStopGrace(appSettings.liveStopGracePeriod)
    }

    let result = await finishTranscription(pumpOutcome: pumpOutcome)

    if let transcriber {
      await transcriber.resetSession()
    }
    transcriber = nil
    await transcriptPump?.finish()
    transcriptPump = nil
    await endActiveInputSession()

    let duration = streamingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    streamingStartTime = nil
    retire(run)

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
        rawPayload: Self.lossyAudioPayload(for: pumpOutcome),
        debugInfo: nil
      )
      delegate?.liveTranscriber(self, didFinishWith: transcription)
    case .failure(let error):
      deliverFailureIfNeeded(error)
    }
  }

  private func finishTranscription(pumpOutcome: FluidAudioPumpOutcome) async -> Result<String, any Error> {
    if let error = processingError ?? pumpOutcome.processingError {
      return .failure(error)
    }
    guard let transcriber else {
      return .failure(FluidAudioModelError.notInstalled)
    }
    do {
      return .success(try await transcriber.finishSession())
    } catch {
      return .failure(error)
    }
  }

  /// Cleanup for runs that never reached `.running`. Publishes no delegate
  /// outcome: the start path throws to its caller instead.
  private func teardownRunResources() async {
    capture?.stop()
    capture = nil
    if let pump = audioPump {
      audioPump = nil
      logPressureDiagnostics(await pump.finish())
    }
    if let transcriber {
      self.transcriber = nil
      await transcriber.resetSession()
    }
    if let transcriptPump {
      self.transcriptPump = nil
      await transcriptPump.finish()
    }
    await endActiveInputSession()
    streamingStartTime = nil
  }

  private func retire(_ run: UUID) {
    guard runID == run else { return }
    runID = nil
    phase = .idle
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}

// MARK: - Callbacks

extension FluidAudioParakeetLiveController {
  private func handleTranscriptEvent(_ event: FluidAudioTranscriptEvent, run: UUID) {
    guard runID == run else { return }
    switch event {
    case .partial(let text):
      latestText = text
      delegate?.liveTranscriber(self, didUpdatePartial: text)
    case .utteranceBoundary(let utterance):
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: utterance)
    }
  }

  /// Prompt mid-run failure notification. Terminal-state authority stays with
  /// `FluidAudioBufferPump.finish()`, so a stop that races this unstructured
  /// hop still observes the error; the `didDeliverFailure` flag keeps the
  /// delegate outcome exactly-once either way.
  private func handleProcessingError(_ error: any Error, run: UUID) {
    guard runID == run, processingError == nil else { return }
    processingError = error
    deliverFailureIfNeeded(error)
  }

  private func deliverFailureIfNeeded(_ error: any Error) {
    guard !didDeliverFailure else { return }
    didDeliverFailure = true
    delegate?.liveTranscriber(self, didFail: error)
  }
}

// MARK: - Lossy-run accounting

extension FluidAudioParakeetLiveController {
  private struct LossyAudioMarker: Codable {
    let provider: String
    let lossyAudio: Bool
    let droppedBufferCount: Int
    let droppedAudioSeconds: Double
    let queuedBufferHighWaterMark: Int
  }

  /// Serialised into `TranscriptionResult.rawPayload` when the bounded queue
  /// discarded captured audio, so a lossy run is never presented as a fully
  /// healthy transcript (issue #715).
  private static func lossyAudioPayload(for outcome: FluidAudioPumpOutcome) -> String? {
    guard outcome.isLossy else { return nil }
    let marker = LossyAudioMarker(
      provider: "fluidaudio-parakeet",
      lossyAudio: true,
      droppedBufferCount: outcome.droppedBufferCount,
      droppedAudioSeconds: (outcome.droppedAudioSeconds * 1000).rounded() / 1000,
      queuedBufferHighWaterMark: outcome.queuedBufferHighWaterMark
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(marker) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func logPressureDiagnostics(_ outcome: FluidAudioPumpOutcome) {
    if outcome.queuedBufferHighWaterMark > 0 {
      logger.debug(
        "FluidAudio queue high-water mark: \(outcome.queuedBufferHighWaterMark, privacy: .public) buffers")
    }
    guard outcome.isLossy else { return }
    logger.warning(
      """
      Dropped \(outcome.droppedBufferCount, privacy: .public) FluidAudio input buffers \
      (~\(outcome.droppedAudioSeconds, format: .fixed(precision: 2), privacy: .public)s) \
      while processing lagged; transcript marked lossy
      """)
  }
}
