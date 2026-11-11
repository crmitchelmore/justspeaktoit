import SpeakCore
import ApplicationServices
import AVFoundation
import AppKit
import Combine
import Foundation
import os.log

/// Owns the dictation session lifecycle. A hotkey, the UI or Shortcuts calls
/// `startSession` (admission in `+SessionStart`, capture in `+StartSteps`);
/// `endSession` (`+SessionStop`) hands the recording to transcription and
/// post-processing (`+SessionPipeline`) and delivery (`+Delivery`). Every path
/// ends by clearing `activeSession`, which retires the session through
/// `SessionRetirement`, and every start leaves a History item, failures
/// included (`+SessionDiagnostics`).
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
  let permissionsManager: PermissionsManager
  let audioInputDeviceManager: AudioInputDeviceManager
  let hotKeyManager: HotKeyManager
  let audioFileManager: AudioFileManager
  let transcriptionManager: TranscriptionManager
  let postProcessingManager: PostProcessingManager
  let historyManager: HistoryManager
  let hudManager: HUDManager
  let personalLexicon: PersonalLexiconService
  let openRouterClient: OpenRouterAPIClient
  let livePolishManager: LivePolishManager
  let liveTextInserter: LiveTextInserter
  let textProcessor: TranscriptionTextProcessor
  let autoCorrectionTracker: AutoCorrectionTracker
  let profileStore: DictationProfileStore
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

  /// Reverts the profile, resumes warming and gives capture back whenever a
  /// session ends or a start is abandoned.
  private(set) lazy var sessionRetirement = SessionRetirement(steps: makeRetirementSteps())
  /// Opens the microphone on hotkey key-down (see `KeyPressPrimerRuntime`).
  private(set) lazy var keyPressPrimer = makeKeyPressPrimer()
  /// Keeps the HUD's microphone/device/provider row current.
  private(set) lazy var captureHealth = makeCaptureHealthMonitor()
  /// Feeds live transcript and polish updates to the previews and the inserter.
  private lazy var liveTranscriptRelay = makeLiveTranscriptRelay()

  /// Hands-free ("armed") dictation. Created eagerly but inert until the user
  /// arms it, which only the hands-free setting allows.
  private(set) lazy var handsFreeCoordinator = makeHandsFreeCoordinator()

  /// Publishes the hands-free runtime state. The coordinator reports every
  /// change here so the menu bar and the HUD tell the same story.
  func setHandsFreeState(_ state: HandsFreeDictationMachine.State) {
    guard handsFreeState != state else { return }
    handsFreeState = state
  }

  /// Keeps the audio recorder and the streaming provider's network path warm
  /// while idle so hotkey→capture does not pay setup cost (issue #663).
  private(set) var captureWarmer: CaptureWarmCoordinator?
  /// Guards against re-entrant calls to endSession (e.g. silence detection + user hotkey racing).
  var isEndingSession = false
  let recordingStopTimeout: TimeInterval = 8
  var cancellables: Set<AnyCancellable> = []
  /// Routes hotkey gestures and shortcuts to session starts and stops.
  private lazy var gestureRouter = SessionGestureRouter(handler: self)
  var audioLevelTimer: Timer?
  /// Level-based silence auto-stop for the current recording.
  var silenceAutoStop = SilenceAutoStop()
  /// Tracks whether the HUD window is visible to skip unnecessary UI updates.
  let hudOcclusion = HUDOcclusionObserver()
  /// Holds the HUD clock and start cue until real audio arrives (see
  /// `MainManager+AudioArrival`).
  var audioArrivalGate: RecordingAudioArrivalGate?
  weak var audioArrivalSession: ActiveSession?

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioInputDeviceManager: AudioInputDeviceManager,
    hotKeyManager: HotKeyManager,
    audioFileManager: AudioFileManager,
    transcriptionManager: TranscriptionManager,
    postProcessingManager: PostProcessingManager,
    historyManager: HistoryManager,
    hudManager: HUDManager,
    personalLexicon: PersonalLexiconService,
    openRouterClient: OpenRouterAPIClient,
    livePolishManager: LivePolishManager,
    liveTextInserter: LiveTextInserter,
    textProcessor: TranscriptionTextProcessor,
    autoCorrectionTracker: AutoCorrectionTracker,
    profileStore: DictationProfileStore
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioInputDeviceManager = audioInputDeviceManager
    self.hotKeyManager = hotKeyManager
    self.audioFileManager = audioFileManager
    self.transcriptionManager = transcriptionManager
    self.postProcessingManager = postProcessingManager
    self.historyManager = historyManager
    self.hudManager = hudManager
    self.personalLexicon = personalLexicon
    self.openRouterClient = openRouterClient
    self.livePolishManager = livePolishManager
    self.liveTextInserter = liveTextInserter
    self.textProcessor = textProcessor
    self.autoCorrectionTracker = autoCorrectionTracker
    self.profileStore = profileStore

    bindSettings()
    liveTranscriptRelay.start()

    recordingSoundPlayer.preload()
    configureHotKeys()
    keyPressPrimer.start()
    captureHealth.start()

    Publishers.CombineLatest(
      appSettings.$connectionPreWarmingEnabled,
      permissionsManager.$statuses.map { $0[.microphone]?.isGranted == true }
    )
    .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
    .dropFirst()
    .receive(on: RunLoop.main)
    .sink { [weak self] enabled, permissionGranted in
      guard enabled, permissionGranted else { return }
      self?.warmUpConnectionIfEnabled()
    }
    .store(in: &cancellables)

    let warmer = CaptureWarmCoordinator(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioInputDeviceManager: audioInputDeviceManager,
      audioFileManager: audioFileManager
    )
    captureWarmer = warmer
    warmer.start()
  }

  private func makeLiveTranscriptRelay() -> LiveTranscriptRelay {
    LiveTranscriptRelay(
      transcription: transcriptionManager,
      polish: livePolishManager,
      inserter: liveTextInserter,
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
    self.stopAudioLevelMonitoring()
    await self.captureWarmer?.invalidate()
  }

  var migrationInProgress = false
  private(set) var captureStarting = false

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
    gestureRouter.register(on: hotKeyManager)

    // Escape has to arrive from whichever app is being dictated into, but only while there
    // is a recording to cancel — outside that window Speak reads no system-wide key presses.
    hotKeyManager.trackRecordingState($state.map { $0 == .recording })

    #if DEBUG
    hotKeyManager.startMonitoring(requestPermission: !CoreJourneyLaunchProfile.isRequested)
    #else
    hotKeyManager.startMonitoring()
    #endif

    // Pre-warm LLM connection at app launch
    warmUpConnectionIfEnabled()
  }

  /// Pre-warms the OpenRouter connection in the background if enabled.
  /// This is called at app launch and when recording starts.
  private func warmUpConnectionIfEnabled() {
    guard appSettings.connectionPreWarmingEnabled else { return }
    guard permissionsManager.status(for: .microphone).isGranted else { return }
    let client = openRouterClient
    Task.detached {
      await client.warmUp()
    }
  }
}

// MARK: - Session start

extension MainManager {
  /// Makes `session` current and resets the live preview, polish and insertion.
  private func activate(_ session: ActiveSession) {
    activeSession = session
    lastErrorMessage = nil
    pendingDeliveryRemedy = nil
    livePreview = ""
    polishedLivePreview = ""
    // Every recording starts from a blank live transcript, including batch
    // modes that never open a live session (issue #643).
    transcriptionManager.resetLiveTranscriptDisplay()

    // Reset live polish for new session
    livePolishManager.reset()

    // Start live text insertion if enabled. The experimental streaming mode
    // patches partials into allowlisted apps via ranged AX replacement; other
    // apps (or with the setting off) keep today's behaviour.
    let useRangedStreaming = streamingInsertionEligible
      && StreamingInsertionAllowlist.allows(session.outputTarget)
    if liveInsertionEnabled || useRangedStreaming {
      liveTextInserter.begin(
        target: session.outputTarget,
        strategy: useRangedStreaming ? .rangedStreaming : .fullValue
      )
      if !liveTextInserter.isActive {
        logger.warning("Live text insertion failed to start - will use standard delivery")
      }
    }
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
    // Every exit closes a primed microphone this start did not take over.
    defer { keyPressPrimer.release(primedInput) }
    guard !migrationInProgress, !captureStarting, activeSession == nil else { return .rejected(.captureFailed) }
    captureStarting = true
    defer { captureStarting = false }
    keyPressPrimer.sessionWillBegin()
    captureWarmer?.sessionWillBegin()

    // Per-app dictation profile: resolve the frontmost app and apply its
    // overrides for this session only. Applied before the API-key check so the
    // check sees the profile's provider. Reverted whenever `activeSession`
    // returns to nil; the early-exit paths below revert explicitly because no
    // session was created yet.
    profileApplier.begin(
      settings: appSettings,
      postProcessing: postProcessingManager,
      profiles: profileStore.profiles,
      frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    )

    if let rejection = await rejectionBeforeStart(trigger: trigger) {
      return rejection
    }

    // Failsafe: if live transcription is still running but we have no activeSession,
    // cancel it so the app can always recover without requiring a restart.
    //
    // The switcher serialises this teardown with a replacement start and guards
    // ownership by run, including when both runs reuse the same controller.
    if transcriptionManager.isLiveTranscribing {
      logger.warning("Live transcription still running without an active session; cancelling to recover")
      transcriptionManager.cancelLiveTranscription()
    }

    retryStore.clear()

    let session = ActiveSession(
      gesture: trigger.historyGesture,
      hotKeyDescription: appSettings.selectedHotKey.displayString,
      trigger: trigger,
      triggerTiming: triggerTiming
    )
    session.outputTarget = TextOutputTarget.capture()
    session.diagnosticContext = makeHistoryDiagnosticContext(includeRequestedContext: true)
    session.isLocalAutomationCapture = true
    activate(session)

    return await runStartSequence(
      for: session, trigger: trigger, preRollBuffers: preRollBuffers, primedInput: primedInput
    )
  }
}
