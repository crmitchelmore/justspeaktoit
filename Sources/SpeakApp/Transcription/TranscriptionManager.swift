import SpeakCore
import AppKit
@preconcurrency import AVFoundation
import Foundation
import Speech
import os.log

private let logger = SpeakLogger.logger(category: "TranscriptionManager")

@MainActor
final class TranscriptionManager: ObservableObject {
  /// Live transcript display state for the current recording. Published as one
  /// value so text, finality, confidence and the owning session can never be
  /// observed out of step with each other (issue #643).
  @Published private(set) var liveTranscript: LiveTranscriptSnapshot = .empty
  @Published private(set) var isLiveTranscribing: Bool = false
  @Published private(set) var utteranceBoundaryText: String?

  /// Owns the identity of the recording whose transcript is on screen.
  let displayScope = LiveTranscriptDisplayScope()

  /// Routes to whichever provider controller owns the current recording and
  /// publishes that ownership through `sessionSourceDidChange`, which is what
  /// binds `displayScope` to the recording actually on air.
  let liveController: SwitchingLiveTranscriber

  private let appSettings: AppSettings
  private let batchRouter: BatchTranscriptionRouter
  private let liveRouter: LiveTranscriptionRouter
  private let stopWait: LiveStopWait

  private var pendingError: Error?
  private var startupGeneration: UUID?
  private var startupTask: Task<Void, Error>?
  private var cancelledStartupGeneration: UUID?

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    batchClient: BatchTranscriptionClient,
    openRouter: OpenRouterAPIClient,
    secureStorage: SecureAppStorage,
    controllerOverride: ((String) -> any LiveTranscriptionController)? = nil,
    stopTimeoutSleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) {
    self.appSettings = appSettings
    self.stopWait = LiveStopWait(sleep: stopTimeoutSleep)
    let liveController = SwitchingLiveTranscriber(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage,
      controllerOverride: controllerOverride
    )
    self.liveController = liveController
    let credentials = TranscriptionProviderCredentials(secureStorage: secureStorage)
    self.batchRouter = BatchTranscriptionRouter(
      settings: appSettings, batchClient: batchClient, openRouter: openRouter, credentials: credentials
    )
    self.liveRouter = LiveTranscriptionRouter(
      settings: appSettings, liveController: liveController, credentials: credentials
    )
    self.liveController.delegate = self
    // Scope the on-screen transcript to whichever controller owns the current
    // live session, so a reused controller's late callbacks can be told apart
    // from the session that is actually recording.
    self.liveController.sessionSourceDidChange = { [weak self] source in
      guard let self else { return }
      if let source {
        self.displayScope.bind(source: source)
      } else {
        self.displayScope.unbind()
      }
    }
  }

  func startLiveTranscription() async throws {
    try await startLiveTranscription(preRollBuffers: [], analyzerFallbackAllowed: true)
  }

  func startLiveTranscription(
    preRollBuffers: [AVAudioPCMBuffer],
    analyzerFallbackAllowed: Bool = true,
    primedInput: PrimedLiveInput? = nil
  ) async throws {
    try await startLiveTranscription(
      preRollBuffers: preRollBuffers, analyzerFallbackAllowed: analyzerFallbackAllowed,
      primedInput: primedInput, onDiagnostic: nil
    )
  }

  func startLiveTranscription(
    preRollBuffers: [AVAudioPCMBuffer],
    analyzerFallbackAllowed: Bool = true,
    primedInput: PrimedLiveInput? = nil,
    onDiagnostic: ((TranscriptionDiagnosticReceipt) -> Void)?
  ) async throws {
        guard !isLiveTranscribing, startupGeneration == nil else {
            throw TranscriptionManagerError.liveSessionAlreadyRunning
        }
    let model = try liveRouter.modelForCurrentMode()
    let language = appSettings.preferredModelLanguage
    let generation = UUID()
    startupGeneration = generation
    defer {
      self.startupTask = nil
      self.startupGeneration = nil
      self.cancelledStartupGeneration = nil
    }
    logger.info("startLiveTranscription - model: \(model), language: \(language ?? "automatic")")
    // Opened before the controller starts: the first partial can arrive while
    // `start()` is still awaiting, and it must land in the new session.
    pendingError = nil
    beginLiveTranscriptDisplaySession()
    liveController.configure(
      language: language,
      model: model
    )
    let startupTask = Task { @MainActor in
      try await Self.performLiveInvocation(model: model, language: language, onDiagnostic: onDiagnostic) {
        try await self.liveController.start(
          preRollBuffers: preRollBuffers,
          analyzerFallbackAllowed: analyzerFallbackAllowed,
          primedInput: primedInput
        )
      }
    }
    self.startupTask = startupTask
    do {
      try await withTaskCancellationHandler {
        try await startupTask.value
      } onCancel: {
        startupTask.cancel()
      }
      // Keep the startup reservation until teardown completes: a replacement
      // must not reuse the controller while this cancelled start is unwinding.
      if cancelledStartupGeneration == generation || Task.isCancelled {
        await liveController.stop()
        throw CancellationError()
      }
    } catch {
      pendingError = nil
      endLiveTranscriptDisplaySession()
      throw error
    }
    isLiveTranscribing = true
  }

  // This receipt observes the configured Switching controller call only. Its
  // internal provider/backend/fallback is opaque, including injected controllers.
  static func performLiveInvocation(
    model: String, language: String?, onDiagnostic: ((TranscriptionDiagnosticReceipt) -> Void)?,
    start: () async throws -> Void
  ) async throws {
    try Task.checkCancellation()
    onDiagnostic?(.handoff(RequestDiagnosticContext(
      provenance: .observedHandoff, model: .project(model), mode: .live, language: .project(language)
    )))
    do {
      try await start()
    } catch {
      onDiagnostic?(.failure(TranscriptionDiagnostics.failure(error, stage: .request)))
      throw error
    }
  }

  func stopLiveTranscription() async throws -> TranscriptionResult {
    // Never replace an outstanding checked continuation: its caller would be
    // suspended forever, even after the replacement stop times out.
    guard !stopWait.isPending else { throw TranscriptionManagerError.liveSessionAlreadyStopping }
    // If there was a mid-session error, still stop the controller so audio resources
    // and preferred input-device sessions are released before surfacing the failure.
    if let error = pendingError {
      pendingError = nil
      isLiveTranscribing = false
      endLiveTranscriptDisplaySession()
      liveController.scheduleStop()
      throw error
    }
    guard isLiveTranscribing else { throw TranscriptionManagerError.liveSessionNotRunning }
    let requestedTimeout = liveController.stopCompletionTimeout
    let timeout = requestedTimeout.isFinite && requestedTimeout > 0 ? requestedTimeout : 10
    return try await stopWait.wait(timeout: timeout) {
      // Capture the run now; a delayed stop must never resolve its target
      // after cancellation has allowed a replacement recording to start.
      self.liveController.scheduleStop()
    } onTimeout: { [weak self] in
      self?.isLiveTranscribing = false
      self?.endLiveTranscriptDisplaySession()
    }
  }

  func cancelLiveTranscription() {
    cancelledStartupGeneration = startupGeneration
    startupTask?.cancel()
    stopWait.cancel(throwing: TranscriptionManagerError.liveSessionNotRunning)
    liveController.scheduleStop()
    isLiveTranscribing = false
    pendingError = nil
    resetLiveTranscriptDisplay()
  }

  /// Marks the live controller cache as stale so it re-reads credentials on next start.
  /// Call this before removing a credential from Keychain to ensure no stale session is reused.
  @MainActor
  func invalidateLiveControllerCache() {
    liveController.markControllersStale()
  }
}

/// Batch routing and live-route lookups are owned by `BatchTranscriptionRouter`
/// and `LiveTranscriptionRouter`; these are the entry points the session uses.
extension TranscriptionManager {
  func transcribeFile(at url: URL) async throws -> TranscriptionResult {
    try await transcribeFile(at: url, onDiagnostic: nil)
  }

  func transcribeFile(
    at url: URL, onDiagnostic: ((TranscriptionDiagnosticReceipt) -> Void)?
  ) async throws -> TranscriptionResult {
    try await batchRouter.transcribeFile(at: url, onDiagnostic: onDiagnostic)
  }

  func batchTranscriptionUsesRemoteService() async -> Bool {
    await batchRouter.batchTranscriptionUsesRemoteService()
  }

  func hasValidBatchAPIKey() async -> Bool {
    await batchRouter.hasValidBatchAPIKey()
  }

  /// Whether the live route for the current mode captures through
  /// `LiveInputEngines.shared`; record-start prepares an engine only then.
  var liveRouteUsesLiveInputEngine: Bool { liveRouter.usesLiveInputEngine }

  /// Read-only projection of the same per-app override applied at session start.
  func liveRouteUsesLiveInputEngine(profiles: [DictationProfile], frontmostBundleID: String?) -> Bool {
    liveRouter.usesLiveInputEngine(profiles: profiles, frontmostBundleID: frontmostBundleID)
  }

  /// The live provider whose API key is missing, for the pre-flight alert.
  func missingLiveAPIKeyProvider() async -> TranscriptionProviderMetadata? {
    await liveRouter.missingAPIKeyProvider()
  }
}

///
/// Kept out of the main class body so the gate and its accessors read as one
/// unit (issue #643).
extension TranscriptionManager {
  var livePartialText: String { liveTranscript.text }
  var liveTextIsFinal: Bool { liveTranscript.isFinal }
  var liveTextConfidence: Double? { liveTranscript.confidence }

  /// Opens a live-transcript display session, clearing the previous
  /// recording's text before any new partial can arrive.
  ///
  /// `source` is the controller that owns the session; production binds it via
  /// `SwitchingLiveTranscriber.sessionSourceDidChange` as the controller starts.
  func beginLiveTranscriptDisplaySession(source: AnyObject? = nil) {
    let sessionID = displayScope.begin()
    if let source {
      displayScope.bind(source: source)
    }
    liveTranscript = LiveTranscriptSnapshot(
      sessionID: sessionID,
      text: "",
      isFinal: true,
      confidence: nil
    )
    utteranceBoundaryText = nil
  }

  /// Detaches the live-transcript display session. The final text stays on
  /// screen; further updates from the finished session are ignored.
  func endLiveTranscriptDisplaySession() {
    displayScope.end()
  }

  /// Clears the live transcript entirely. Called when a recording starts so
  /// batch modes — which never open a live session — cannot show the previous
  /// recording's text.
  func resetLiveTranscriptDisplay() {
    displayScope.end()
    liveTranscript = .empty
    utteranceBoundaryText = nil
  }
}

extension TranscriptionManager: LiveTranscriptionSessionDelegate {
  /// Admits a display update only from the controller that owns the active
  /// session. Late or out-of-order events from a superseded recording are
  /// dropped rather than repainting the live view (issue #643).
  ///
  /// Returns `true` when the update was published, so callers that also need to
  /// act on ownership (e.g. closing the session on finish) can reuse the single
  /// ownership check rather than repeating it.
  @discardableResult
  private func applyLiveDisplayUpdate(
    from session: any LiveTranscriptionController,
    text: String,
    isFinal: Bool,
    confidence: Double?
  ) -> Bool {
    guard displayScope.accepts(session) else { return false }
    liveTranscript = LiveTranscriptSnapshot(
      sessionID: displayScope.activeSessionID,
      text: text,
      isFinal: isFinal,
      confidence: confidence
    )
    return true
  }

  func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
    applyLiveDisplayUpdate(
      from: session,
      text: text,
      isFinal: liveTranscript.isFinal,
      confidence: liveTranscript.confidence
    )
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didUpdateWith update: LiveTranscriptionUpdate
  ) {
    applyLiveDisplayUpdate(
      from: session,
      text: update.text,
      isFinal: update.isFinal,
      confidence: update.confidence
    )
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didFinishWith result: TranscriptionResult
  ) {
    // Ownership must be checked before touching the pending stop, not just
    // before publishing its text: an old provider must not finish a new run.
    guard displayScope.accepts(session) else { return }
    // Guard against double-resume of continuation - the controllers have their own
    // guards but this is belt-and-suspenders safety
    guard let cont = stopWait.take() else {
      // Already finished or no continuation - log but don't crash
      logger.warning("didFinishWith called but no continuation (already finished?)")
      return
    }
    isLiveTranscribing = false
    // Only the controller that owns the on-screen session may publish its
    // final text or close the session; a late finish from a superseded
    // recording must leave the current session alone (issue #643).
    let published = applyLiveDisplayUpdate(
      from: session,
      text: result.text,
      isFinal: true,
      confidence: result.confidence
    )
    if published {
      endLiveTranscriptDisplaySession()
    }
    cont.resume(returning: result)
  }

  func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) {
    // Late failures must neither consume a new stop nor poison its next stop.
    guard displayScope.accepts(session) else { return }
    if let cont = stopWait.take() {
      // We're in the middle of stopping - resume with the error
      isLiveTranscribing = false
      if displayScope.accepts(session) {
        endLiveTranscriptDisplaySession()
      }
      cont.resume(throwing: error)
    } else {
      // Error happened mid-session - store it for when stop is called
      pendingError = error
      // Keep isLiveTranscribing true so stopLiveTranscription doesn't throw early
    }
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didDetectUtteranceBoundary utterance: String
  ) {
    guard displayScope.accepts(session) else { return }
    utteranceBoundaryText = utterance
  }
}
