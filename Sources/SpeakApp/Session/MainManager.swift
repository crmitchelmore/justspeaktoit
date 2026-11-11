import SpeakCore
import ApplicationServices
import AVFoundation
import AppKit
import Combine
import Foundation
import os.log

/// Owns the dictation session lifecycle and publishes its state. In order, a
/// session passes through these owners:
///
/// 1. `SessionGestureRouter` turns hotkey gestures (and `KeyPressPrimerRuntime`
///    the key-down microphone) into `startSession`/`endSession` calls; the UI,
///    Shortcuts and `HandsFreeDictationCoordinator` call the same two methods.
/// 2. `SessionStartPipeline` admits the start (profile, API key, microphone,
///    capture reservation) and brings capture up through
///    `RecordingStartSequencer`, claiming `CaptureWarmCoordinator`'s staged
///    recorder when it can.
/// 3. `SessionCaptureRuntime` owns the recording while it captures: level
///    metering, silence auto-stop, the audio-arrival gate for the HUD clock and
///    start cue, and the one stop in progress.
/// 4. `endSession` (`+SessionStop`) stops the recorder; `SessionCompletionPipeline`
///    then transcribes and post-processes, and `SessionDelivery` delivers.
/// 5. Clearing `activeSession` retires the session through `SessionRetirement`.
///
/// `ReprocessingCoordinator` runs the two flows without a recording
/// (reprocessing a History item, retrying post-processing). Every start leaves a
/// History item, failures included (`+SessionDiagnostics`).
@MainActor
final class MainManager: ObservableObject {
  enum State: Equatable {
    case idle
    case recording
    case processing
    case delivering
    case completed(HistoryItem)
    case failed(String)
  }

  @Published var state: State = .idle
  @Published private(set) var livePreview: String = ""
  @Published private(set) var polishedLivePreview: String = ""
  @Published private(set) var isPolishing: Bool = false
  @Published var lastErrorMessage: String?
  /// The setting change that would have let the last delivery reach the app the
  /// user expected. Offered as a one-click action in the menu bar until the next
  /// session starts or the user applies it.
  @Published var pendingDeliveryRemedy: DeliverySettingsRemedy?
  /// The last failed post-processing, offered for retry.
  @Published var retryStore = PostProcessingRetryStore()
  var canRetryPostProcessing: Bool { retryStore.canRetry }

  /// Runtime state of hands-free dictation. Published so the menu bar can show
  /// that the microphone is armed while the HUD is hidden or behind a window.
  @Published private(set) var handsFreeState: HandsFreeDictationMachine.State = .off

  /// Set when a live-recording attempt is aborted because the selected
  /// transcription provider has no API key stored. Observed by `MainView`
  /// to present an alert with an "Add API Key" deep-link CTA.
  @Published var missingLiveAPIKeyAlert: MissingLiveAPIKeyAlert?

  /// Whether live text insertion is enabled based on current settings
  private var liveInsertionEnabled: Bool {
    appSettings.speedMode.usesLivePolish && appSettings.textOutputMethod != .clipboardOnly
  }

  /// Whether the experimental streaming-insertion setting can apply to this
  /// configuration (issue #611). The per-app allowlist is checked at session
  /// start against the captured output target.
  private var streamingInsertionEligible: Bool {
    appSettings.streamingInsertionEnabled
      && appSettings.textOutputMethod != .clipboardOnly
      && isStreamingTranscriptionMode
  }

  var isStreamingTranscriptionMode: Bool {
    appSettings.transcriptionMode == .liveNative
      || (appSettings.transcriptionMode == .localModel && appSettings.localTranscriptionMode == .streaming)
  }

  let appSettings: AppSettings
  let capture: SessionCaptureServices
  let transcriptionManager: TranscriptionManager
  let text: SessionTextServices
  let historyManager: HistoryManager
  let hudManager: HUDManager
  private let connectionPrewarmer: ConnectionPrewarmer
  /// Installed by AppEnvironment only for the consent-gated direct analytics transport.
  var analyticsCapture: ((ProductAnalyticsEvent) -> Void)?
  let logger = SpeakLogger.logger(category: "MainManager")
  let recordingSoundPlayer = RecordingSoundPlayer()
  /// Applies/reverts per-app dictation profile overrides for a session.
  let profileApplier = SessionProfileApplier()

  /// Reservation shared with Voice Edit for the recorder and live transcriber
  /// (issue #673). Dictation claims it in `startSession` and gives it back
  /// whenever `activeSession` clears.
  let captureOwnership = CaptureSessionOwnership()

  /// Where the last dictation landed, for Voice Edit's "last dictation"
  /// fallback (issue #673).
  let insertionRecords = InsertionRecordStore()

  var activeSession: ActiveSession? {
    didSet {
      // Every session-teardown path clears `activeSession`, so this is the one
      // place a session is retired (see `SessionRetirement`).
      if activeSession == nil {
        sessionRetirement.retire(oldValue)
      }
    }
  }

  /// Keeps the audio recorder and the streaming provider's network path warm
  /// while idle so hotkey→capture does not pay setup cost (issue #663).
  let captureWarmer: CaptureWarmCoordinator
  /// Reverts the profile, resumes warming and gives capture back whenever a
  /// session ends or a start is abandoned.
  private(set) lazy var sessionRetirement = SessionRetirement(steps: makeRetirementSteps())
  /// Opens the microphone on hotkey key-down (see `KeyPressPrimerRuntime`).
  private(set) lazy var keyPressPrimer = makeKeyPressPrimer()
  /// Keeps the HUD's microphone/device/provider row current.
  private(set) lazy var captureHealth = makeCaptureHealthMonitor()
  /// Feeds live transcript and polish updates to the previews and the inserter.
  private lazy var liveTranscriptRelay = makeLiveTranscriptRelay()
  /// Metering, silence auto-stop, the audio-arrival gate and the stop in progress.
  private(set) lazy var captureRuntime = makeCaptureRuntime()
  /// Admission and capture bring-up for every start.
  private(set) lazy var startPipeline = makeStartPipeline()
  /// Transcription, post-processing and delivery after every stop.
  private(set) lazy var completionPipeline = makeCompletionPipeline()
  /// Reprocessing History items and retrying post-processing.
  private(set) lazy var reprocessing = makeReprocessingCoordinator()

  /// Hands-free ("armed") dictation. Created eagerly but inert until the user
  /// arms it, which only the hands-free setting allows.
  private(set) lazy var handsFreeCoordinator = makeHandsFreeCoordinator()

  /// Publishes the hands-free runtime state. The coordinator reports every
  /// change here so the menu bar and the HUD tell the same story.
  func setHandsFreeState(_ state: HandsFreeDictationMachine.State) {
    guard handsFreeState != state else { return }
    handsFreeState = state
  }

  /// Guards against re-entrant calls to endSession (e.g. silence detection + user hotkey racing).
  var isEndingSession: Bool { captureRuntime.isEnding }
  /// Whether a start is between admission and capture.
  var captureStarting: Bool { startPipeline.isStarting }
  let recordingStopTimeout: TimeInterval = 8
  var cancellables: Set<AnyCancellable> = []
  /// Routes hotkey gestures and shortcuts to session starts and stops.
  private lazy var gestureRouter = SessionGestureRouter(handler: self)

  init(
    appSettings: AppSettings,
    capture: SessionCaptureServices,
    transcriptionManager: TranscriptionManager,
    text: SessionTextServices,
    historyManager: HistoryManager,
    hudManager: HUDManager,
    connectionPrewarmer: ConnectionPrewarmer
  ) {
    self.appSettings = appSettings
    self.capture = capture
    self.transcriptionManager = transcriptionManager
    self.text = text
    self.historyManager = historyManager
    self.hudManager = hudManager
    self.connectionPrewarmer = connectionPrewarmer
    self.captureWarmer = CaptureWarmCoordinator(
      appSettings: appSettings,
      permissionsManager: capture.permissions,
      audioInputDeviceManager: capture.devices,
      audioFileManager: capture.audioFiles
    )

    bindSettings()
    liveTranscriptRelay.start()

    recordingSoundPlayer.preload()
    configureHotKeys()
    keyPressPrimer.start()
    captureHealth.start()
    connectionPrewarmer.observeChanges()
    captureWarmer.start()
  }

  private func makeLiveTranscriptRelay() -> LiveTranscriptRelay {
    LiveTranscriptRelay(
      transcription: transcriptionManager,
      polish: text.livePolish,
      inserter: text.liveTextInserter,
      hud: hudManager,
      settings: appSettings,
      session: LiveTranscriptRelay.Session(
        isRecording: { [weak self] in self?.state == .recording },
        activeSession: { [weak self] in self?.activeSession },
        liveInsertionEnabled: { [weak self] in self?.liveInsertionEnabled ?? false },
        publishPreview: { [weak self] in self?.livePreview = $0 },
        publishPolishedPreview: { [weak self] in self?.polishedLivePreview = $0 },
        publishIsPolishing: { [weak self] in self?.isPolishing = $0 }
      )
    )
  }

  /// Completes asynchronous warm-resource teardown before AppKit permits the
  /// process to exit, so the prepared recorder cannot leave an empty file.
  func prepareForTermination() async {
    captureRuntime.stop()
    await captureWarmer.invalidate()
  }

  var migrationInProgress = false

  var isBusy: Bool {
    switch state {
    case .idle, .completed, .failed:
      return false
    case .recording, .processing, .delivering:
      return true
    }
  }

  private func configureHotKeys() {
    #if DEBUG
    if CoreJourneyLaunchProfile.isRequested, CoreJourneyLaunchProfile.current?.runsBatchJourney != true { return }
    #endif
    gestureRouter.register(on: capture.hotKeys)

    // Escape has to arrive from whichever app is being dictated into, but only while there
    // is a recording to cancel — outside that window Speak reads no system-wide key presses.
    capture.hotKeys.trackRecordingState($state.map { $0 == .recording })

    #if DEBUG
    capture.hotKeys.startMonitoring(requestPermission: !CoreJourneyLaunchProfile.isRequested)
    #else
    capture.hotKeys.startMonitoring()
    #endif

    // Pre-warm LLM connection at app launch
    connectionPrewarmer.warmUpIfEnabled()
  }
}

// MARK: - Session start

extension MainManager: SessionStartHost {
  var mayStartSession: Bool { !migrationInProgress && activeSession == nil }

  /// Makes `session` current and resets the live preview, polish and insertion.
  func activate(_ session: ActiveSession) {
    retryStore.clear()
    activeSession = session
    lastErrorMessage = nil
    pendingDeliveryRemedy = nil
    livePreview = ""
    polishedLivePreview = ""
    // Every recording starts from a blank live transcript, including batch
    // modes that never open a live session (issue #643).
    transcriptionManager.resetLiveTranscriptDisplay()

    // Reset live polish for new session
    text.livePolish.reset()

    // Start live text insertion if enabled. The experimental streaming mode
    // patches partials into allowlisted apps via ranged AX replacement; other
    // apps (or with the setting off) keep today's behaviour.
    let useRangedStreaming = streamingInsertionEligible
      && StreamingInsertionAllowlist.allows(session.outputTarget)
    if liveInsertionEnabled || useRangedStreaming {
      text.liveTextInserter.begin(
        target: session.outputTarget,
        strategy: useRangedStreaming ? .rangedStreaming : .fullValue
      )
      if !text.liveTextInserter.isActive {
        logger.warning("Live text insertion failed to start - will use standard delivery")
      }
    }
  }

  func captureDidStart(for session: ActiveSession) {
    state = .recording
  }

  func publishStartRejection(_ message: String) {
    state = .failed(message)
    lastErrorMessage = message
  }

  func publishMissingLiveAPIKey(_ alert: MissingLiveAPIKeyAlert) {
    missingLiveAPIKeyAlert = alert
  }

  func makeAdmissionDiagnosticContext() -> HistoryDiagnosticContext {
    makeHistoryDiagnosticContext(includeRequestedContext: true)
  }

  func failStartedSession(message: String) {
    cleanupAfterFailure(message: message, preserveFile: false)
  }

  // Internal rather than private so the hands-free coordinator can start the
  // same session the hotkey would have.
  @discardableResult
  func startSession(
    trigger: SessionTriggerSource,
    preRollBuffers: [AVAudioPCMBuffer] = [],
    triggerTiming: SessionTriggerTiming = .nonHotKey(),
    primedInput: PrimedLiveInputReservation? = nil
  ) async -> HandsFreeCaptureStartOutcome {
    await startPipeline.start(
      SessionStartPipeline.Request(
        trigger: trigger,
        preRollBuffers: preRollBuffers,
        triggerTiming: triggerTiming,
        primedInput: primedInput
      )
    )
  }
}

// MARK: - Reprocessing

extension MainManager: ReprocessingHost {
  func adopt(_ session: ActiveSession) {
    activeSession = session
  }

  func releaseActiveSession() {
    activeSession = nil
  }

  func publish(_ state: State) {
    self.state = state
  }

  func publishFailure(_ message: String) {
    state = .failed(message)
    lastErrorMessage = message
  }

  func clearDeliveryFeedback() {
    lastErrorMessage = nil
    pendingDeliveryRemedy = nil
  }

  func makeDiagnosticContext() -> HistoryDiagnosticContext {
    makeHistoryDiagnosticContext()
  }

  func failForMissingAPIKey(_ session: ActiveSession, phase: HistoryError.Phase, message: String) async {
    await handleMissingAPIKey(session, phase: phase, message: message)
  }

  func completeRetryDelivery(remedy: DeliverySettingsRemedy?) {
    retryStore.clear()
    pendingDeliveryRemedy = remedy
  }
}

// MARK: - Session completion

extension MainManager: SessionCompletionHost {
  func offerPostProcessingRetry(for session: ActiveSession) -> Bool {
    retryStore.offer(for: session)
  }
}
