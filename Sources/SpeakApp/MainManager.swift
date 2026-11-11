import SpeakCore
import ApplicationServices
import AVFoundation
import AppKit
import Combine
import Foundation
import os.log

// swiftlint:disable file_length
@MainActor
// swiftlint:disable type_body_length
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
  private let recordingSoundPlayer = RecordingSoundPlayer()
  /// Applies/reverts per-app dictation profile overrides for a session.
  private let profileApplier = SessionProfileApplier()

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
      // place profile overrides are reverted back to the user's own settings —
      // and the one place capture pre-warming can safely resume.
      if activeSession == nil {
        if let oldValue, oldValue.isLocalAutomationCapture {
          historyManager.finishAutomationCapture(id: oldValue.id, item: nil)
        }
        profileApplier.end(settings: appSettings, postProcessing: postProcessingManager)
        captureWarmer?.sessionDidEnd()
        captureOwnership.release(.dictation)
        keyPressPrimer.sessionDidEnd()
      }
    }
  }

  /// Opens the microphone on hotkey key-down (see `KeyPressPrimerRuntime`).
  private(set) lazy var keyPressPrimer = KeyPressPrimerRuntime(owner: self)

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
  private var captureWarmer: CaptureWarmCoordinator?
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

  enum SessionStopError: LocalizedError {
    case recordingStopTimedOut(seconds: TimeInterval)

    var errorDescription: String? {
      switch self {
      case .recordingStopTimedOut(let seconds):
        let timeout = String(format: "%.0f", seconds)
        return "Stopping recording took too long (\(timeout)s timeout)."
      }
    }
  }

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
    bindLiveUpdates()

    recordingSoundPlayer.preload()
    configureHotKeys()
    keyPressPrimer.start()
    setupCaptureHealthBindings()

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

  /// Keeps the sound profile, hands-free arming and the offered delivery
  /// remedy in step with settings and permissions.
  private func bindSettings() {
    recordingSoundPlayer.profile = appSettings.recordingSoundProfile
    appSettings.$recordingSoundProfile
      .receive(on: RunLoop.main)
      .sink { [weak self] profile in
        self?.recordingSoundPlayer.profile = profile
      }
      .store(in: &cancellables)

    // Turning hands-free off or selecting an incompatible transcription route
    // must tear down a live detector, not just stop future arming.
    Publishers.CombineLatest3(
      appSettings.$handsFreeDictationEnabled,
      appSettings.$transcriptionMode,
      appSettings.$liveTranscriptionModel
    )
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.disarmHandsFreeIfDisabled()
      }
      .store(in: &cancellables)

    // @Published emits before the value is stored; hopping to the run loop
    // lets the reconciliation read the new settings.
    Publishers.CombineLatest4(
      appSettings.$appSwitchDelivery,
      appSettings.$textOutputMethod,
      appSettings.$streamingInsertionEnabled,
      permissionsManager.$statuses
    )
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.reconcilePendingDeliveryRemedy()
      }
      .store(in: &cancellables)
  }

  /// Feeds live transcript and live polish updates to the previews and the
  /// live text inserter.
  private func bindLiveUpdates() {
    transcriptionManager.$liveTranscript
      .receive(on: RunLoop.main)
      .sink { [weak self] snapshot in
        self?.handleLiveTranscriptSnapshot(snapshot)
      }
      .store(in: &cancellables)

    // Subscribe to live polish updates
    livePolishManager.$polishedTail
      .receive(on: RunLoop.main)
      .sink { [weak self] polished in
        self?.polishedLivePreview = polished
      }
      .store(in: &cancellables)

    livePolishManager.$isPolishing
      .receive(on: RunLoop.main)
      .sink { [weak self] isPolishing in
        self?.isPolishing = isPolishing
      }
      .store(in: &cancellables)

    // Connect live polish completion to live text inserter
    livePolishManager.onPolishComplete = { [weak self] polished in
      guard let self, self.liveInsertionEnabled, self.liveTextInserter.isActive else { return }
      self.liveTextInserter.update(with: polished)
    }

    // Trigger immediate polish on utterance boundary (AssemblyAI sub-turn signal)
    transcriptionManager.$utteranceBoundaryText
      .compactMap { $0 }
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self, self.appSettings.speedMode.usesLivePolish, self.state == .recording else {
          return
        }
        Task { @MainActor [weak self] in
          guard let self else { return }
          await self.livePolishManager.polishNow(
            stableContext: "",
            tailText: self.transcriptionManager.livePartialText
          )
        }
      }
      .store(in: &cancellables)
  }

  /// Completes asynchronous warm-resource teardown before AppKit permits the
  /// process to exit, so the prepared recorder cannot leave an empty file.
  func prepareForTermination() async {
    self.stopAudioLevelMonitoring()
    await self.captureWarmer?.invalidate()
  }

  /// Applies a live-transcript snapshot to the preview and the HUD.
  ///
  /// Delivery is deferred onto the run loop, so a snapshot published by one
  /// recording can arrive after the next one has already started. Snapshots
  /// that no longer belong to the current live session are dropped instead of
  /// repainting the previous recording's text over the live view (issue #643).
  private func handleLiveTranscriptSnapshot(_ snapshot: LiveTranscriptSnapshot) {
    guard snapshot.sessionID == transcriptionManager.liveTranscript.sessionID else { return }
    handleLiveTextUpdate(snapshot.text)
    hudManager.updateLiveTranscription(
      text: snapshot.text,
      isFinal: snapshot.isFinal,
      confidence: snapshot.confidence
    )
  }

  /// Handle live text updates and trigger live polish if enabled
  private func handleLiveTextUpdate(_ text: String) {
    livePreview = text

    // Latency checkpoint: first non-empty partial while still recording.
    if self.state == .recording, !text.isEmpty,
       let session = self.activeSession, session.firstPartialReceived == nil {
      session.firstPartialReceived = Date()
      if let firstPartialMs = SessionLatencyMetrics.milliseconds(
        from: session.captureStarted, to: session.firstPartialReceived
      ) {
        self.logger.info("Latency: first partial \(firstPartialMs)ms after capture start")
      }
    }

    // Live insertion during recording (live-polish full-value mode or the
    // experimental ranged streaming mode; `update` no-ops when inactive).
    if state == .recording && liveTextInserter.isActive {
      liveTextInserter.update(with: text)
    }

    // Trigger live polish if speed mode uses it
    guard appSettings.speedMode.usesLivePolish else { return }
    guard state == .recording else { return }

    livePolishManager.textDidChange(
      stableContext: "",  // Simplified - no transcript state model yet
      tailText: text
    )
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

  func toggleRecordingFromUI() {
    guard !isEndingSession else { return }
    if activeSession == nil {
      let triggerTiming = SessionTriggerTiming.nonHotKey()
      Task { await startSession(trigger: .uiButton, triggerTiming: triggerTiming) }
    } else {
      Task { await endSession(trigger: .uiButton) }
    }
  }

  // MARK: - Automation (App Intents / Shortcuts)

  /// Whether a dictation session is currently active. Automation callers use
  /// this instead of `state` so an in-flight stop still reads as active.
  var isDictationSessionActive: Bool {
    activeSession != nil
  }

  /// Starts a dictation session on behalf of a Shortcuts action, reusing the
  /// exact hotkey/UI session pipeline. Returns false when no session started;
  /// `state` and `missingLiveAPIKeyAlert` carry the reason.
  @discardableResult
  func startDictationFromAutomation() async -> Bool {
    await startSession(trigger: .automation)
    return activeSession != nil
  }

  /// Ends the active dictation session on behalf of a Shortcuts action and
  /// returns the delivered history item, or nil when the session failed (the
  /// failure message is available via `state` / `lastErrorMessage`).
  func stopDictationFromAutomation() async -> HistoryItem? {
    await endSession(trigger: .automation)
    if case .completed(let item) = state {
      return item
    }
    return nil
  }

  func retryPostProcessing() {
    guard let retryData = retryStore.entryToRetry(sessionActive: activeSession != nil) else { return }
    Task { await performRetryPostProcessing(with: retryData) }
  }

  func userRequestedStopDueToError() {
    guard activeSession != nil else { return }
    cancelRecordingByUser(reason: "User cancelled")
  }

  func cancelRecordingWithEscape() {
    guard appSettings.cancelRecordingOnEscape, state == .recording, activeSession != nil else { return }
    logger.info("Cancelling recording via Escape key")
    cancelRecordingByUser(reason: "Cancelled by user (Escape)")
  }

  /// A user cancellation either keeps the audio as a cancelled History entry
  /// that can be reprocessed later, or deletes it and records nothing.
  private func cancelRecordingByUser(reason: String) {
    activeSession?.errors.append(HistoryError(phase: .recording, message: reason, debugDescription: nil))
    cleanupAfterFailure(
      message: "Recording cancelled", preserveFile: appSettings.keepAudioOnCancel,
      transcriptPolicy: .discard, historyRequiresAudio: true
    )
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

  /// Returns true (and sets `missingLiveAPIKeyAlert`) when the chosen live
  /// transcription model needs an API key that has not been stored. Callers
  /// should abort the session start when this returns true.
  private func presentMissingLiveAPIKeyAlertIfNeeded() async -> Bool {
    guard appSettings.transcriptionMode == .liveNative else { return false }
    guard let missing = await transcriptionManager.missingLiveAPIKeyProvider() else {
      return false
    }
    let modelID = appSettings.liveTranscriptionModel
    let modelName = ModelCatalog.liveTranscription.first { $0.id == modelID }?.displayName ?? modelID
    missingLiveAPIKeyAlert = MissingLiveAPIKeyAlert(
      provider: missing,
      modelDisplayName: modelName
    )
    return true
  }

  func rawTranscriptionSubheadline() -> String {
    guard appSettings.transcriptionMode == .localModel else {
      return "Preparing raw transcript"
    }
    if LocalModelManager.shared.isModelLoaded(appSettings.localTranscriptionModel) {
      return "Transcribing locally on this Mac"
    }
    return "Loading local model and transcribing. First run can take a minute."
  }

  /// Checks that must pass before a session exists. Returns the rejection
  /// after undoing the profile and warm-capture hand-off, or nil when the
  /// start may proceed with `.dictation` capture reserved.
  private func rejectionBeforeStart(trigger: SessionTriggerSource) async -> HandsFreeCaptureStartOutcome? {
    if trigger == .handsFree,
      !HandsFreeDictationPolicy.supportsCapture(
        modelID: appSettings.liveTranscriptionModel,
        isStreaming: appSettings.transcriptionMode == .liveNative
      ) {
      return abandonStart(.rejected(.unsupportedConfiguration))
    }

    if await presentMissingLiveAPIKeyAlertIfNeeded() {
      return abandonStart(.rejected(.captureFailed))
    }

    if audioFileManager.requiresPhysicalInput && audioInputDeviceManager.devices.isEmpty {
      let rejection = abandonStart(.rejected(.audioUnavailable))
      showStartFailure(
        "No microphone connected. Plug in a USB or Bluetooth microphone and try again.",
        headline: "No microphone connected",
        message: "Plug in a USB or Bluetooth microphone and try again."
      )
      return rejection
    }

    // Voice Edit may own the shared recorder and live stream right now. Starting
    // on top of it would hit `alreadyRecording` and the failure path would then
    // cancel Voice Edit's capture, so refuse before touching either (issue #673).
    guard captureOwnership.reserve(.dictation) else {
      let rejection = abandonStart(.rejected(.captureFailed))
      showStartFailure(
        "Voice edit is in progress. Finish or cancel it first.",
        headline: "Voice edit in progress",
        message: "Finish or cancel the voice edit, then start dictation.",
        displayDuration: 3
      )
      return rejection
    }
    return nil
  }

  /// No session was created, so `activeSession`'s teardown will not run:
  /// revert the profile and let capture pre-warming resume here.
  private func abandonStart(_ rejection: HandsFreeCaptureStartOutcome) -> HandsFreeCaptureStartOutcome {
    profileApplier.end(settings: appSettings, postProcessing: postProcessingManager)
    captureWarmer?.sessionDidEnd()
    return rejection
  }

  private func showStartFailure(
    _ stateMessage: String,
    headline: String,
    message: String,
    displayDuration: TimeInterval? = nil
  ) {
    state = .failed(stateMessage)
    lastErrorMessage = stateMessage
    hudManager.finishFailure(headline: headline, message: message, displayDuration: displayDuration)
  }

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

  /// Brings up capture (and the live stream) for a session that now exists,
  /// then plays the start cue. Abandons quietly if the session ended meanwhile.
  private func runStartSequence(
    for session: ActiveSession,
    trigger: SessionTriggerSource,
    preRollBuffers: [AVAudioPCMBuffer],
    primedInput: PrimedLiveInputReservation?
  ) async -> HandsFreeCaptureStartOutcome {
    // Claim the recorder staged while idle. Returns nil — and the cold path
    // runs — whenever the environment moved since it was staged.
    let warmContext = captureWarmer?.claimWarmContext()
    let liveInputPreparation = LiveInputPreparation(
      deviceManager: audioInputDeviceManager,
      engines: LiveInputEngines.shared,
      primed: primedInput
    )

    do {
      // Issue #641: the start cue is played by the sequencer *after* capture is
      // proven live (and, in streaming modes, after the audio tap is running),
      // so the user is never invited to speak into a microphone that isn't
      // listening yet. The pre-warm path (issue #663) runs inside the same
      // step — a claimed staged recorder still has to prove it is capturing.
      let startStream = makeStartStreamStep(
        for: session, trigger: trigger, preRollBuffers: preRollBuffers, primedInput: primedInput
      )
      // The live engine's input node is built before the recorder opens the
      // microphone; built afterwards it stalled stream start (and the cue) by
      // ~3 s on Bluetooth inputs. See `LiveInputEngineStore`. Routes that
      // capture through their own engine (WhisperKit) would never claim it.
      let prepareStream: RecordingStartSequencer.Step? = audioFileManager.requiresPhysicalInput
        && transcriptionManager.liveRouteUsesLiveInputEngine
        ? { await liveInputPreparation.prepare() }
        : nil
      if let primedInput, prepareStream == nil {
        // This route builds its own input node (or none); it must not do so
        // beside the primer's open microphone.
        await keyPressPrimer.closeBeforeStart(primedInput)
      }
      let showsHUD = showRecordingHUDIfNeeded(for: trigger)
      let sequencer = RecordingStartSequencer(
        isSessionCurrent: { [weak self] in self?.activeSession === session },
        prepareStream: prepareStream,
        discardPreparedStream: { await liveInputPreparation.finish(startFailed: true) },
        startCapture: makeStartCaptureStep(for: session, warmContext: warmContext, showsHUD: showsHUD),
        discardCapture: { [weak self] in await self?.discardStartedCapture() },
        startStream: startStream,
        discardStream: { [weak self] in self?.transcriptionManager.cancelLiveTranscription() },
        playCue: { [weak self] in self?.requestRecordingStartCue(for: session) }
      )
      let timeline = try await sequencer.run()
      await liveInputPreparation.finish()
      recordStartTimeline(for: session, timeline: timeline)
      await recordKeyDownLatency(for: session, primedInput: primedInput)
      return .started
    } catch is RecordingStartAbort {
      await liveInputPreparation.finish(startFailed: true)
      hudManager.cancelAwaitingAudio()
      // Not a failure: the session ended while startup was suspended, and the
      // sequencer has already torn down whatever it brought up. Touching the
      // shared failure path here would clobber the session that replaced it.
      logger.info("Recording start abandoned: the session ended before capture was ready")
      return .rejected(.captureFailed)
    } catch {
      await liveInputPreparation.finish(startFailed: true)
      return failStart(of: session, error: error)
    }
  }

  private func failStart(of session: ActiveSession, error: Error) -> HandsFreeCaptureStartOutcome {
    guard sessionProcessingShouldContinue(session) else { return .rejected(.captureFailed) }
    session.errors.append(
      HistoryError(
        phase: .recording,
        message: "Failed to start recording",
        debugDescription: error.localizedDescription
      )
    )
    cleanupAfterFailure(message: error.localizedDescription, preserveFile: false)
    return .rejected(HandsFreeDictationMachine.Failure(error))
  }

  /// Shows the HUD as "Getting ready" when this session shows one. Returns
  /// whether it does.
  private func showRecordingHUDIfNeeded(for trigger: SessionTriggerSource) -> Bool {
    // A hands-free capture always moves the HUD to the recording pane, even
    // when the user hides the HUD for their own sessions: the armed pane
    // otherwise claims the app only listens while it in fact records.
    // Showing that the microphone captures is a privacy duty, not a taste.
    let showsHUD = appSettings.showHUDDuringSessions || trigger == .handsFree
    guard showsHUD else { return false }
    // Up straight away as "Getting ready"; its clock starts only when the
    // microphone delivers real audio, never while words can't be heard.
    // Uses the cached microphone status: each TCC query costs 13-35 ms
    // before capture (#611), and `startRecording` makes the authoritative
    // check moments later; the HUD health is refreshed once capture is live.
    hudManager.updateCaptureHealth(buildCaptureHealthSnapshot())
    hudManager.beginRecording(profileName: profileApplier.activeProfileName, awaitingAudio: true)
    return true
  }

  /// The sequencer step that opens the live stream, nil for batch modes.
  private func makeStartStreamStep(
    for session: ActiveSession,
    trigger: SessionTriggerSource,
    preRollBuffers: [AVAudioPCMBuffer],
    primedInput: PrimedLiveInputReservation?
  ) -> RecordingStartSequencer.Step? {
    guard isStreamingTranscriptionMode else { return nil }
    return { [weak self, transcriptionManager, preRollBuffers, trigger, primedInput] in
      let primedCapture = await primedInput?.value
      try await transcriptionManager.startLiveTranscription(
        preRollBuffers: preRollBuffers,
        analyzerFallbackAllowed: trigger != .handsFree,
        primedInput: primedCapture,
        onDiagnostic: { [weak self] receipt in
          Self.retainBatchDiagnostic(receipt, for: session, activeSession: self?.activeSession)
        }
      )
      guard self?.activeSession === session else { return }
      session.liveTranscriptSessionID = transcriptionManager.liveTranscript.sessionID
    }
  }

  /// The sequencer step that starts the recorder and publishes the recording.
  private func makeStartCaptureStep(
    for session: ActiveSession,
    warmContext: CaptureWarmContext?,
    showsHUD: Bool
  ) -> RecordingStartSequencer.Step {
    { [weak self] in
      guard let self else { return }
      let recording = try await self.audioFileManager.startRecording(
        warmContext: warmContext,
        owner: .dictation
      )
      // The stop could have landed while `startRecording()` was suspended.
      // Publish nothing for a session that is already over — throw away the
      // capture that just came up instead.
      guard self.activeSession === session else {
        await self.discardStartedCapture()
        throw RecordingStartAbort.sessionEnded
      }
      self.recordCaptureStart(for: session, wasWarm: recording.usedWarmRecorder)
      self.state = .recording
      session.events.append(
        HistoryEvent(
          kind: .recordingStarted,
          description: "Recording started via \(session.gesture.rawValue)"
        )
      )
      if showsHUD {
        self.hudManager.updateCaptureHealth(self.buildCaptureHealthSnapshot())
      }
      self.beginAwaitingAudio(for: session)
      self.startAudioLevelMonitoring()
    }
  }

  /// Plays the "recording started" cue, unless the user already stopped (or a
  /// newer session replaced this one) while capture was coming up — a late cue
  /// after the stop cue would be worse than no cue at all.
  func playRecordingStartCue(for session: ActiveSession) {
    guard self.activeSession === session, self.state == .recording else {
      self.logger.info("Skipping start cue: session ended before capture was ready")
      return
    }
    guard appSettings.recordingSoundsEnabled else { return }
    recordingSoundPlayer.play(.start, volume: appSettings.recordingSoundVolume)
  }

  /// Latency checkpoint: the recorder is live. hotkey → capture-start is the
  /// cold-start figure competitors market, so log it explicitly every session,
  /// tagged with whether the pre-warmed recorder was used (issue #663) so the
  /// dashboard percentiles can be read against the warm/cold split.
  ///
  /// Called from the start sequencer's capture step, so the checkpoint is taken
  /// the moment capture is *proven* live rather than when it was requested.
  private func recordCaptureStart(for session: ActiveSession, wasWarm: Bool) {
    session.captureStarted = Date()
    session.captureStartedUptime = ProcessInfo.processInfo.systemUptime
    if let coldStartMs = session.captureStartMilliseconds {
      let path = wasWarm ? "pre-warmed" : "cold"
      self.logger.info("Latency: capture started \(coldStartMs)ms after trigger (\(path, privacy: .public))")
    }
    if let keyDownMs = session.keyDownToCaptureMilliseconds {
      self.logger.info("Latency: capture started \(keyDownMs)ms after key-down")
    }
  }

  /// Throws away capture that came up for a session nobody is listening to any
  /// more (the user stopped, or a replacement session started, while the start
  /// was suspended). Without this the recorder keeps running and the file is
  /// never claimed by any session.
  private func discardStartedCapture() async {
    stopAudioLevelMonitoring()
    await audioFileManager.cancelRecording(deleteFile: true)
  }

  /// Records the full start timeline (capture, streaming tap, cue) in history
  /// so a clipped-start report can be diagnosed from the session alone
  /// (issue #641).
  private func recordStartTimeline(for session: ActiveSession, timeline: RecordingStartTimeline) {
    let summary = timeline.diagnosticSummary
    guard !summary.isEmpty else { return }
    self.logger.info("Recording start timeline: \(summary, privacy: .public)")
    session.events.append(
      HistoryEvent(
        kind: .recordingStarted,
        description: "Start timeline — \(summary)"
      )
    )
  }

  /// Plays the stop cue, moves to processing and records the stop in History.
  private func markRecordingStopped(
    _ session: ActiveSession,
    trigger: SessionTriggerSource,
    tailDuration: TimeInterval
  ) {
    if appSettings.recordingSoundsEnabled {
      recordingSoundPlayer.play(.stop, volume: appSettings.recordingSoundVolume)
    }

    state = .processing
    session.recordingEnded = Date()
    if isStreamingTranscriptionMode {
      // Move the HUD off the "Recording" timer immediately. Otherwise the
      // user sees the recording timer frozen at the release time while we
      // close the audio file and drain the live provider's finalisation
      // budget — which on AssemblyAI can be ~2s and reads as a hang for
      // very short presses where the WebSocket `Begin` never arrived.
      hudManager.beginTranscribing(subheadline: "Finalising transcript")
    }
    var stopDescription = "Recording stopped via \(trigger.historyGesture.rawValue)"
    if tailDuration > 0 {
      stopDescription += " (tail +\(String(format: "%.1f", tailDuration))s)"
    }
    session.events.append(
      HistoryEvent(
        kind: .recordingStopped,
        timestamp: Date(),
        description: stopDescription
      )
    )
  }

  func endSession(trigger: SessionTriggerSource) async {
    guard !isEndingSession else { return }
    guard let session = activeSession else { return }
    isEndingSession = true
    defer { isEndingSession = false }

    // Latency checkpoint: user asked to stop (before the optional tail sleep).
    session.stopRequested = Date()

    stopAudioLevelMonitoring()

    let tailDuration = max(appSettings.postRecordingTailDuration, 0)
    if tailDuration > 0 {
      do {
        try await Task.sleep(nanoseconds: UInt64(tailDuration * 1_000_000_000))
      } catch {
        // Ignored: sleep cancellation simply means we stop immediately.
      }
    }
    guard sessionProcessingShouldContinue(session) else { return }

    markRecordingStopped(session, trigger: trigger, tailDuration: tailDuration)

    do {
      let summary = try await stopRecordingWithTimeout()
      guard sessionProcessingShouldContinue(session) else { return }
      session.recordingSummary = summary
      session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)

      let transcribed = isStreamingTranscriptionMode
        ? try await finishLiveTranscription(for: session)
        : try await transcribeRecording(summary, for: session)
      guard transcribed else { return }
      let correctedText = applyVoiceCommandsAndLexicon(to: session.transcriptionResult?.text ?? "", for: session)
      guard let processed = await postProcessIfNeeded(correctedText, for: session) else { return }
      await deliver(processed.text, postProcessingFailure: processed.failureMessage, for: session)
    } catch {
      guard sessionProcessingShouldContinue(session) else { return }
      session.errors.append(
        HistoryError(
          phase: .transcription,
          message: "Processing failed",
          debugDescription: error.localizedDescription
        )
      )
      cleanupAfterFailure(message: error.localizedDescription, preserveFile: true)
    }
  }

}
// swiftlint:enable type_body_length
extension MainManager {
  static func retainBatchDiagnostic(
    _ receipt: TranscriptionManager.BatchDiagnosticReceipt, for session: ActiveSession, activeSession: ActiveSession?
  ) {
    guard activeSession === session, !Task.isCancelled, let context = session.diagnosticContext else { return }
    var handoff = context.observedHandoff
    var failure = context.requestFailure
    switch receipt {
    case .handoff(let observed):
      guard observed.provenance == .observedHandoff else { return }
      handoff = observed
    case .failure(let observed):
      failure = observed
    }
    session.diagnosticContext = HistoryDiagnosticContext(
      capturedAt: context.capturedAt, appVersion: context.appVersion, appBuild: context.appBuild,
      operatingSystem: context.operatingSystem, processIdentifier: context.processIdentifier,
      microphonePermission: context.microphonePermission, inputDeviceName: context.inputDeviceName,
      providerLabel: context.providerLabel, latencyTier: context.latencyTier,
      transcriptionMode: context.transcriptionMode, transcriptionModel: context.transcriptionModel,
      postProcessingModel: context.postProcessingModel, speedMode: context.speedMode,
      requestContext: context.requestContext, observedHandoff: handoff, requestFailure: failure,
      postProcessingObservation: context.postProcessingObservation
    )
  }

  static func retainPostProcessingDiagnostic(
    _ observation: RequestDiagnosticContext.PostProcessingObservation,
    for session: ActiveSession, activeSession: ActiveSession?
  ) {
    guard activeSession === session, !Task.isCancelled, let context = session.diagnosticContext else { return }
    session.diagnosticContext = HistoryDiagnosticContext(
      capturedAt: context.capturedAt, appVersion: context.appVersion, appBuild: context.appBuild,
      operatingSystem: context.operatingSystem, processIdentifier: context.processIdentifier,
      microphonePermission: context.microphonePermission, inputDeviceName: context.inputDeviceName,
      providerLabel: context.providerLabel, latencyTier: context.latencyTier,
      transcriptionMode: context.transcriptionMode, transcriptionModel: context.transcriptionModel,
      postProcessingModel: context.postProcessingModel, speedMode: context.speedMode,
      requestContext: context.requestContext, observedHandoff: context.observedHandoff,
      requestFailure: context.requestFailure, postProcessingObservation: observation
    )
  }

  func makeRecordingSummary(from url: URL, fallbackDuration: TimeInterval)
    -> RecordingSummary {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? fallbackDuration
    let resolvedDuration = duration.isFinite && duration > 0 ? duration : fallbackDuration
    let startedAt = (attributes[.creationDate] as? Date) ?? Date()
    return RecordingSummary(
      id: UUID(),
      url: url,
      startedAt: startedAt,
      duration: resolvedDuration,
      fileSize: fileSize
    )
  }
}

// @Implement: This file is the main lifecycle management for a transcription session. It orchestrates all the dependencies and passes commands between them.
// It depends on hotkey manager to tell it when to start recording. Based on the config from app settings it should know when to start recording either on: "a press and hold until release" OR "double tap until the next single tap"
// It should also depend on audio file manager to process and store the recorded audio file. This should always happen when we record as a backup and in the background even and especially when we are using live transcription
// The normal behaviour will be to pass the live audio to the transcription manager for native osx live transcription but it could be a streaming api or other at that point.
// This file also depends on the Post Processing Manager. If app settings say post processing should happen, it hands off the raw transcription to the Post Processing Manager and receives it back when complete.
// When a complete recording, transcribing, post processing etc cycle is complete this file should write a HistoryItem to the history manager. This includes if there are errors in any part of the process. Every time recording is started should result in some kind of history item even if it's only partially complete, and capture error information in detail.
// This file should use the text output to perform the output once all of the steps have been finished.
// This file also takes the HUD Manager as a dependency and calls the lifecycle events on the HUD Manager for it to be updated.
// It should call out to the HUD view to present that to the user the hud manager should update it. And pass any error messages back to it if things fail.
// Finally, after a session has completed and either succeeded and output the text or failed and an error has displayed, this file is responsible for cleaning up any open resources or sessions and closing them down properly.
// swiftlint:enable file_length
