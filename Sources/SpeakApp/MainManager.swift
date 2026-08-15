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
  @Published private(set) var canRetryPostProcessing: Bool = false

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

  private var cachedRetryData: RetryData?

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
  let logger = Logger(subsystem: "com.github.speakapp", category: "MainManager")
  private let recordingSoundPlayer = RecordingSoundPlayer()
  /// Applies/reverts per-app dictation profile overrides for a session.
  private let profileApplier = SessionProfileApplier()

  var activeSession: ActiveSession? {
    didSet {
      // Every session-teardown path clears `activeSession`, so this is the one
      // place profile overrides are reverted back to the user's own settings —
      // and the one place capture pre-warming can safely resume.
      if activeSession == nil {
        profileApplier.end(settings: appSettings, postProcessing: postProcessingManager)
        captureWarmer?.sessionDidEnd()
      }
    }
  }

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
  private var hotKeyTokens: [HotKeyListenerToken] = []
  private var shortcutTokens: [ShortcutListenerToken] = []
  private var lastDoubleTapEventUptime: TimeInterval = 0
  var audioLevelTimer: Timer?
  var silenceStartTime: Date?
  // Cached silence settings for timer callback (avoids @Published access in hot path)
  var cachedSilenceEnabled: Bool = false
  var cachedSilenceThreshold: Float = 0
  var cachedSilenceDuration: TimeInterval = 0
  /// Tracks whether the HUD window is visible to skip unnecessary UI updates
  var isHUDOccluded: Bool = false
  var occlusionObserver: NSObjectProtocol?

  struct RetryData {
    let transcriptionResult: TranscriptionResult
    let recordingSummary: RecordingSummary?
    let personalCorrections: PersonalLexiconHistorySummary?
    let lexiconContext: PersonalLexiconContext
    let originalHistoryItemID: UUID?
  }

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

  // swiftlint:disable:next function_body_length
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

    recordingSoundPlayer.preload()
    configureHotKeys()
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

  func retryPostProcessing() {
    guard canRetryPostProcessing, let retryData = cachedRetryData else { return }
    guard activeSession == nil else { return }
    Task { await performRetryPostProcessing(with: retryData) }
  }

  private func clearRetryData() {
    cachedRetryData = nil
    canRetryPostProcessing = false
  }

  func userRequestedStopDueToError() {
    guard let session = activeSession else { return }
    session.errors.append(
      HistoryError(phase: .recording, message: "User cancelled", debugDescription: nil)
    )
    cleanupAfterFailure(message: "Recording cancelled", preserveFile: false)
  }

  func cancelRecordingWithEscape() {
    guard state == .recording, activeSession != nil else { return }
    logger.info("Cancelling recording via Escape key")
    activeSession?.errors.append(
      HistoryError(phase: .recording, message: "Cancelled by user (Escape)", debugDescription: nil)
    )
    cleanupAfterFailure(message: "Recording cancelled", preserveFile: false)
  }

  /// Hands-free replaces press-to-talk with press-to-arm.
  private func handleHoldStartGesture(triggerTiming: SessionTriggerTiming) async {
    guard appSettings.hotKeyActivationStyle.allowsHold else { return }
    if await handleHandsFreeHotKey() { return }
    await startSession(trigger: .hold, triggerTiming: triggerTiming)
  }

  /// The arming press already consumed the gesture, so releasing the key must
  /// not stop a hands-free capture the detector is still driving.
  private func handleHoldEndGesture() async {
    guard appSettings.hotKeyActivationStyle.allowsHold else { return }
    guard !handsFreeArmsHotKey else { return }
    await endSession(trigger: .hold)
  }

  private func handleSingleTapGesture() async {
    guard appSettings.hotKeyActivationStyle.allowsDoubleTap else { return }
    guard !handsFreeArmsHotKey else { return }
    guard let session = activeSession, session.gesture == .doubleTap else { return }
    await endSession(trigger: .singleTap)
  }

  /// Double-tap toggles: it arms hands-free dictation when that mode is on,
  /// otherwise it starts a session or ends the one it started.
  private func handleDoubleTapGesture(triggerTiming: SessionTriggerTiming) async {
    guard appSettings.hotKeyActivationStyle.allowsDoubleTap else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastDoubleTapEventUptime >= 0.25 else { return }
    lastDoubleTapEventUptime = now

    if await handleHandsFreeHotKey() { return }

    if let session = activeSession {
      guard session.gesture == .doubleTap else { return }
      await endSession(trigger: .doubleTap)
    } else {
      await startSession(trigger: .doubleTap, triggerTiming: triggerTiming)
    }
  }

  private func configureHotKeys() {
    hotKeyTokens.append(
      hotKeyManager.register(gesture: .holdStart) { [weak self] in
        // Stamped here, before the actor hop, so the latency dashboard measures
        // from the key press rather than from where `startSession` gets to run.
        let triggerTiming = SessionTriggerTiming.recognisedHotKey()
        Task { @MainActor in
          await self?.handleHoldStartGesture(triggerTiming: triggerTiming)
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .holdEnd) { [weak self] in
        Task { @MainActor in
          await self?.handleHoldEndGesture()
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .doubleTap) { [weak self] in
        let triggerTiming = SessionTriggerTiming.recognisedHotKey()
        Task { @MainActor in
          await self?.handleDoubleTapGesture(triggerTiming: triggerTiming)
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .singleTap) { [weak self] in
        Task { @MainActor in
          await self?.handleSingleTapGesture()
        }
      }
    )

    shortcutTokens.append(
      hotKeyManager.register(shortcut: .commandR) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          self.retryPostProcessing()
        }
      }
    )

    shortcutTokens.append(
      hotKeyManager.register(shortcut: .escape) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          self.cancelRecordingWithEscape()
        }
      }
    )

    hotKeyManager.startMonitoring()

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

  private func rawTranscriptionSubheadline() -> String {
    guard appSettings.transcriptionMode == .localModel else {
      return "Preparing raw transcript"
    }
    if LocalModelManager.shared.isModelLoaded(appSettings.localTranscriptionModel) {
      return "Transcribing locally on this Mac"
    }
    return "Loading local model and transcribing. First run can take a minute."
  }

  // Internal rather than private so the hands-free coordinator can start the
  // same session the hotkey would have.
  @discardableResult
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func startSession(
    trigger: SessionTriggerSource,
    preRollBuffers: [AVAudioPCMBuffer] = [],
    triggerTiming: SessionTriggerTiming = .nonHotKey()
  ) async -> HandsFreeCaptureStartOutcome {
    guard activeSession == nil else { return .rejected(.captureFailed) }
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

    if trigger == .handsFree {
      guard HandsFreeDictationPolicy.supportsCapture(
        modelID: appSettings.liveTranscriptionModel,
        isStreaming: appSettings.transcriptionMode == .liveNative
      )
      else {
        profileApplier.end(settings: appSettings, postProcessing: postProcessingManager)
        captureWarmer?.sessionDidEnd()
        return .rejected(.unsupportedConfiguration)
      }
    }

    if await presentMissingLiveAPIKeyAlertIfNeeded() {
      profileApplier.end(settings: appSettings, postProcessing: postProcessingManager)
      captureWarmer?.sessionDidEnd()
      return .rejected(.captureFailed)
    }

    if audioInputDeviceManager.devices.isEmpty {
      profileApplier.end(settings: appSettings, postProcessing: postProcessingManager)
      captureWarmer?.sessionDidEnd()
      let message = "No microphone connected. Plug in a USB or Bluetooth microphone and try again."
      state = .failed(message)
      lastErrorMessage = message
      hudManager.finishFailure(
        headline: "No microphone connected",
        message: "Plug in a USB or Bluetooth microphone and try again."
      )
      return .rejected(.audioUnavailable)
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

    clearRetryData()

    let gesture = trigger.historyGesture
    let session = ActiveSession(
      gesture: gesture,
      hotKeyDescription: appSettings.selectedHotKey.displayString,
      trigger: trigger,
      triggerTiming: triggerTiming
    )
    session.outputTarget = TextOutputTarget.capture()
    session.diagnosticContext = makeHistoryDiagnosticContext()
    activeSession = session
    lastErrorMessage = nil
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

    // Claim the recorder staged while idle. Returns nil — and the cold path
    // runs — whenever the environment moved since it was staged.
    let warmContext = captureWarmer?.claimWarmContext()

    do {
      let recording = try await audioFileManager.startRecording(
        warmContext: warmContext,
        owner: .dictation
      )
      recordCaptureStart(for: session, wasWarm: recording.usedWarmRecorder)
      state = .recording
      session.events.append(
        HistoryEvent(
          kind: .recordingStarted,
          description: "Recording started via \(gesture.rawValue)"
        )
      )
      if appSettings.recordingSoundsEnabled {
        recordingSoundPlayer.play(.start, volume: appSettings.recordingSoundVolume)
      }
      // A hands-free capture always moves the HUD to the recording pane, even
      // when the user hides the HUD for their own sessions: the armed pane
      // otherwise claims the app only listens while it in fact records.
      // Showing that the microphone captures is a privacy duty, not a taste.
      if appSettings.showHUDDuringSessions || trigger == .handsFree {
        permissionsManager.refresh(.microphone)
        hudManager.updateCaptureHealth(buildCaptureHealthSnapshot())
        hudManager.beginRecording(profileName: profileApplier.activeProfileName)
      }
      startAudioLevelMonitoring()
      if isStreamingTranscriptionMode {
        try await transcriptionManager.startLiveTranscription(
          preRollBuffers: preRollBuffers,
          analyzerFallbackAllowed: trigger != .handsFree
        )
      }
      return .started
    } catch {
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
  }

  /// Latency checkpoint: the recorder is live. hotkey → capture-start is the
  /// cold-start figure competitors market, so log it explicitly every session,
  /// tagged with whether the pre-warmed recorder was used (issue #663) so the
  /// dashboard percentiles can be read against the warm/cold split.
  private func recordCaptureStart(for session: ActiveSession, wasWarm: Bool) {
    session.captureStarted = Date()
    session.captureStartedUptime = ProcessInfo.processInfo.systemUptime
    if let coldStartMs = session.captureStartMilliseconds {
      let path = wasWarm ? "pre-warmed" : "cold"
      self.logger.info("Latency: capture started \(coldStartMs)ms after trigger (\(path, privacy: .public))")
    }
  }

  // swiftlint:disable cyclomatic_complexity function_body_length
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
    let stopDescription: String
    if tailDuration > 0 {
      let tailText = String(format: "%.1f", tailDuration)
      stopDescription =
        "Recording stopped via \(trigger.historyGesture.rawValue) (tail +\(tailText)s)"
    } else {
      stopDescription = "Recording stopped via \(trigger.historyGesture.rawValue)"
    }
    session.events.append(
      HistoryEvent(
        kind: .recordingStopped,
        timestamp: Date(),
        description: stopDescription
      )
    )

    do {
      let summary = try await stopRecordingWithTimeout()
      guard sessionProcessingShouldContinue(session) else { return }
      session.recordingSummary = summary
      session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)

      if isStreamingTranscriptionMode {
        session.transcriptionStarted = Date()
        let result = try await transcriptionManager.stopLiveTranscription()
        guard sessionProcessingShouldContinue(session) else { return }
        session.transcriptionEnded = Date()
        session.transcriptionResult = result
        session.modelsUsed.insert(result.modelIdentifier)
        session.modelUsages.append(ModelUsage(modelIdentifier: result.modelIdentifier, phase: .transcriptionLive))
        session.events.append(
          HistoryEvent(kind: .transcriptionReceived, description: "Live transcription complete")
        )
        if let cost = result.cost {
          session.recordCostFragment(cost)
        }
        // Log network exchange for live transcription
        let durationStr = String(format: "%.1f", result.duration)
        var didRecordLiveExchange = false
        if result.modelIdentifier.hasPrefix("local/streaming/") {
          let localRuntime: String
          if FluidAudioParakeetModel.matches(result.modelIdentifier) {
            localRuntime = "fluidaudio"
          } else if WhisperKitStreamingModel.matches(result.modelIdentifier) {
            localRuntime = "whisperkit"
          } else {
            #if APP_STORE
            localRuntime = "unknown-local"
            #else
            localRuntime = "sherpa-onnx"
            #endif
          }
          let localURL = URL(string: "local://\(localRuntime)")!
            .appendingPathComponent(result.modelIdentifier)
          session.networkExchanges.append(
            HistoryNetworkExchange(
              url: localURL,
              method: "On-Device",
              requestHeaders: [
                "Model": result.modelIdentifier,
                "Duration": "\(durationStr)s"
              ],
              requestBodyPreview: "Local streaming audio (\(durationStr) seconds)",
              responseCode: 200,
              responseHeaders: [:],
              responseBodyPreview: "Transcript: \(String(result.text.prefix(500)))"
            )
          )
          didRecordLiveExchange = true
        }
        if !didRecordLiveExchange, result.modelIdentifier.contains("deepgram") {
          session.networkExchanges.append(
            HistoryNetworkExchange(
              url: URL(string: "wss://api.deepgram.com/v1/listen")!,
              method: "WebSocket",
              requestHeaders: [
                "Model": result.modelIdentifier,
                "Duration": "\(durationStr)s",
              ],
              requestBodyPreview: "Streaming audio (\(durationStr) seconds)",
              responseCode: 200,
              responseHeaders: [:],
              responseBodyPreview: result.rawPayload ?? "Transcript: \(String(result.text.prefix(500)))"
            )
          )
        } else if !didRecordLiveExchange, result.modelIdentifier.contains("apple") {
          session.networkExchanges.append(
            HistoryNetworkExchange(
              url: URL(string: "local://SFSpeechRecognizer")!,
              method: "On-Device",
              requestHeaders: [
                "Model": result.modelIdentifier,
                "Duration": "\(durationStr)s",
              ],
              requestBodyPreview: "On-device speech recognition (\(durationStr) seconds)",
              responseCode: 200,
              responseHeaders: [:],
              responseBodyPreview: "Transcript: \(String(result.text.prefix(500)))"
            )
          )
        }
      } else {
        hudManager.beginTranscribing(subheadline: rawTranscriptionSubheadline())
        session.transcriptionStarted = Date()
        if appSettings.transcriptionMode == .batchRemote {
          guard
            await ensureBatchAPIKeyAvailable(
              for: session,
              message:
                "Batch transcription requires an OpenRouter API key. Add one in Settings › API Keys."
            )
          else {
            return
          }
        }
        let result = try await transcriptionManager.transcribeFile(at: summary.url)
        guard sessionProcessingShouldContinue(session) else { return }
        session.transcriptionEnded = Date()
        session.transcriptionResult = result
        session.modelsUsed.insert(result.modelIdentifier)
        let usagePhase: ModelUsagePhase = appSettings.transcriptionMode == .localModel
          ? .transcriptionLocal
          : .transcriptionBatch
        session.modelUsages.append(ModelUsage(modelIdentifier: result.modelIdentifier, phase: usagePhase))
        session.events.append(
          HistoryEvent(
            kind: .transcriptionReceived,
            description: appSettings.transcriptionMode == .localModel
              ? "Local model transcription complete"
              : "Batch transcription complete"
          )
        )
        if appSettings.transcriptionMode == .localModel {
          session.networkExchanges.append(
            HistoryNetworkExchange(
              url: URL(string: "local://whisperkit")!,
              method: "On-Device",
              requestHeaders: [
                "Model": result.modelIdentifier,
                "Duration": String(format: "%.1fs", result.duration)
              ],
              requestBodyPreview: "Local audio file: \(summary.url.lastPathComponent)",
              responseCode: 200,
              responseHeaders: [:],
              responseBodyPreview: "Transcript: \(String(result.text.prefix(500)))"
            )
          )
        } else if let payload = result.rawPayload {
          session.networkExchanges.append(
            HistoryNetworkExchange(
              url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
              method: "POST",
              requestHeaders: [
                "Model": result.modelIdentifier,
                "Content-Type": "application/json",
              ],
              requestBodyPreview: "JSON payload with \(summary.url.lastPathComponent) audio",
              responseCode: 200,
              responseHeaders: [:],
              responseBodyPreview: String(payload.prefix(800))
            )
          )
        }
        if let cost = result.cost {
          session.recordCostFragment(cost)
        }
      }

      // Process voice commands (e.g., "copy pasta" → clipboard content)
      let baseText = textProcessor.process(session.transcriptionResult?.text ?? "")
      let lexiconContext = makeLexiconContext(for: baseText, destination: nil)
      let corrections = personalLexicon.apply(to: baseText, context: lexiconContext)
      session.personalCorrections = PersonalLexiconHistorySummary(
        applied: corrections.applied,
        suggestions: corrections.suggestions,
        contextTags: Array(lexiconContext.tags).sorted(),
        destinationApplication: lexiconContext.destinationApplication
      )
      session.lexiconContext = lexiconContext
      var finalText = corrections.transformedText
      var postProcessingFailureNotice: (headline: String, message: String)?

      if shouldRunPostProcessing() {
        hudManager.beginPostProcessing()
        session.postProcessingStarted = Date()
        guard
          await ensurePostProcessingAPIKeyAvailable(
            for: session,
            message:
              "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."
          )
        else {
          return
        }
        let configuredModel = appSettings.postProcessingModel
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPostProcessingModel =
          configuredModel.isEmpty
          ? "inception/mercury"
          : configuredModel
        let postProcessingInput = finalText
        let outcomeResult = await postProcessingManager.process(
          rawText: postProcessingInput,
          context: session.lexiconContext,
          corrections: session.personalCorrections,
          onStreamingUpdate: { [weak self] accumulatedText in
            Task { @MainActor in
              self?.hudManager.updateStreamingText(accumulatedText)
            }
          }
        )
        guard sessionProcessingShouldContinue(session) else { return }
        switch outcomeResult {
        case .success(let outcome):
          session.postProcessingEnded = Date()
          session.postProcessingOutcome = outcome
          finalText = outcome.processed
          if let response = outcome.response {
            session.events.append(
              HistoryEvent(kind: .postProcessingReceived, description: "Post-processing complete")
            )
            if let payload = response.rawPayload {
              session.networkExchanges.append(
                HistoryNetworkExchange(
                  url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                  method: "POST",
                  requestHeaders: ["Model": resolvedPostProcessingModel],
                  requestBodyPreview: postProcessingRequestPreview(
                    systemPrompt: outcome.systemPrompt,
                    rawText: postProcessingInput
                  ),
                  responseCode: 200,
                  responseHeaders: [:],
                  responseBodyPreview: String(payload.prefix(800))
                )
              )
            }
            session.modelsUsed.insert(resolvedPostProcessingModel)
            session.modelUsages.append(ModelUsage(modelIdentifier: resolvedPostProcessingModel, phase: .postProcessing))
            if let cost = response.cost {
              session.recordCostFragment(cost)
            }
          } else {
            // Streaming completed without ChatResponse, still mark completion
            session.events.append(
              HistoryEvent(kind: .postProcessingReceived, description: "Post-processing complete (streamed)")
            )
            session.modelsUsed.insert(resolvedPostProcessingModel)
            session.modelUsages.append(ModelUsage(modelIdentifier: resolvedPostProcessingModel, phase: .postProcessing))
          }
        case .failure(let error):
          session.postProcessingEnded = Date()
          let friendly = Self.friendlyPostProcessingMessage(
            for: error,
            modelIdentifier: resolvedPostProcessingModel
          )
          session.errors.append(
            HistoryError(
              phase: .postProcessing,
              message: friendly,
              debugDescription: error.localizedDescription
            )
          )
          session.events.append(HistoryEvent(kind: .error, description: friendly))
          attachFailureDiagnostics(to: session)
          postProcessingFailureNotice = (headline: "Post-processing failed", message: friendly)

          if let transcriptionResult = session.transcriptionResult {
            cachedRetryData = RetryData(
              transcriptionResult: transcriptionResult,
              recordingSummary: session.recordingSummary,
              personalCorrections: session.personalCorrections,
              lexiconContext: session.lexiconContext,
              originalHistoryItemID: session.id
            )
            canRetryPostProcessing = true
            hudManager.finishFailure(headline: "Post-processing failed", message: friendly, showRetryHint: true)
          } else {
            hudManager.finishFailure(headline: "Post-processing failed", message: friendly)
          }
        }
      }

      state = .delivering
      if postProcessingFailureNotice == nil {
        hudManager.beginDelivering()
      }

      // Handle live text insertion finalization
      var liveFinalizationResult: LiveTextInserter.FinalizationResult = .deferred
      if liveTextInserter.isActive {
        liveFinalizationResult = liveTextInserter.applyPolishedFinal(finalText)
        liveTextInserter.end()
      }
      // Latency checkpoint: when the first character actually reached the target
      // app via live insertion (nil when the session never streamed text).
      session.firstInsertion = self.liveTextInserter.firstInsertionAt

      switch liveFinalizationResult {
      case .applied:
        session.outputMethod = .accessibility
      case .deferred:
        let output = SmartTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
        let outputResult = output.output(text: finalText, target: session.outputTarget)
        session.outputMethod = outputResult.method

        if let error = outputResult.error {
          session.errors.append(
            HistoryError(
              phase: .output,
              message: "Failed to deliver text",
              debugDescription: error.localizedDescription
            )
          )
          hudManager.finishFailure(headline: "Delivery failed", message: error.localizedDescription)
          state = .failed(error.localizedDescription)
          lastErrorMessage = error.localizedDescription
          attachFailureDiagnostics(to: session)
          let historyItem = session.buildHistoryItem(finalText: finalText)
          await historyManager.append(historyItem)
          livePolishManager.reset()
          liveTextInserter.reset()
          activeSession = nil
          return
        }
      case .failed(let error):
        session.errors.append(
          HistoryError(
            phase: .output,
            message: "Failed to deliver text",
            debugDescription: error.localizedDescription
          )
        )
        hudManager.finishFailure(headline: "Delivery failed", message: error.localizedDescription)
        state = .failed(error.localizedDescription)
        lastErrorMessage = error.localizedDescription
        attachFailureDiagnostics(to: session)
        let historyItem = session.buildHistoryItem(finalText: finalText)
        await historyManager.append(historyItem)
        livePolishManager.reset()
        liveTextInserter.reset()
        activeSession = nil
        return
      }

      // Start monitoring for user corrections (auto-corrections feature)
      let focusedElement = session.outputTarget?.focusedElement ?? getFocusedElement()
      let appName = session.outputTarget?.applicationName
        ?? NSWorkspace.shared.frontmostApplication?.localizedName
      autoCorrectionTracker.startMonitoring(insertedText: finalText, element: focusedElement, app: appName)

      session.outputDelivered = Date()

      session.events.append(
        HistoryEvent(kind: .outputDelivered, description: "Output delivered successfully")
      )
      session.destination = appName
      session.lexiconContext = makeLexiconContext(for: finalText, destination: appName)
      if let summary = session.personalCorrections {
        session.personalCorrections = summary.updatingContext(
          tags: Array(session.lexiconContext.tags).sorted(),
          destination: appName
        )
      }
      let historyItem = session.buildHistoryItem(finalText: finalText)
      await historyManager.append(historyItem)
      if let notice = postProcessingFailureNotice {
        lastErrorMessage = notice.message
        state = .failed(notice.message)
      } else {
        if let stopToFinalMs = SessionLatencyMetrics.milliseconds(
          from: session.stopRequested, to: session.outputDelivered
        ) {
          hudManager.finishSuccess(
            message: "Delivered in \(SessionLatencyMetrics.formattedMilliseconds(stopToFinalMs))"
          )
        } else {
          hudManager.finishSuccess(message: "Delivered")
        }
        state = .completed(historyItem)
      }

      livePolishManager.reset()
      liveTextInserter.reset()
      activeSession = nil
    } catch {
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
  // swiftlint:enable cyclomatic_complexity function_body_length

  // swiftlint:disable:next function_body_length
  private func performRetryPostProcessing(with retryData: RetryData) async {
    state = .processing
    lastErrorMessage = nil
    hudManager.beginPostProcessing()

    let session = ActiveSession(gesture: .uiButton, hotKeyDescription: appSettings.selectedHotKey.displayString)
    session.outputTarget = TextOutputTarget.capture()
    session.diagnosticContext = makeHistoryDiagnosticContext()
    activeSession = session
    session.transcriptionResult = retryData.transcriptionResult
    session.recordingSummary = retryData.recordingSummary
    session.personalCorrections = retryData.personalCorrections
    session.lexiconContext = retryData.lexiconContext
    session.events.append(
      HistoryEvent(kind: .postProcessingSubmitted, description: "Retry post-processing requested")
    )

    let baseText = retryData.transcriptionResult.text
    var finalText = baseText
    if retryData.personalCorrections != nil {
      finalText = personalLexicon.apply(to: baseText, context: retryData.lexiconContext).transformedText
    }

    guard
      await ensurePostProcessingAPIKeyAvailable(
        for: session,
        message: "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."
      )
    else {
      return
    }

    let configuredModel = appSettings.postProcessingModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedPostProcessingModel =
      configuredModel.isEmpty ? "inception/mercury" : configuredModel
    let postProcessingInput = finalText

    session.postProcessingStarted = Date()
    let outcomeResult = await postProcessingManager.process(
      rawText: postProcessingInput,
      context: retryData.lexiconContext,
      corrections: retryData.personalCorrections
    )

    switch outcomeResult {
    case .success(let outcome):
      session.postProcessingEnded = Date()
      session.postProcessingOutcome = outcome
      finalText = outcome.processed

      session.events.append(
        HistoryEvent(kind: .postProcessingReceived, description: "Retry post-processing complete")
      )
      session.modelsUsed.insert(resolvedPostProcessingModel)
      session.modelUsages.append(ModelUsage(modelIdentifier: resolvedPostProcessingModel, phase: .postProcessing))

      if let response = outcome.response {
        if let payload = response.rawPayload {
          session.networkExchanges.append(
            HistoryNetworkExchange(
              url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
              method: "POST",
              requestHeaders: ["Model": resolvedPostProcessingModel],
              requestBodyPreview: postProcessingRequestPreview(
                systemPrompt: outcome.systemPrompt,
                rawText: postProcessingInput
              ),
              responseCode: 200,
              responseHeaders: [:],
              responseBodyPreview: String(payload.prefix(800))
            )
          )
        }
        if let cost = response.cost {
          session.recordCostFragment(cost)
        }
      }

      state = .delivering
      hudManager.beginDelivering()
      let output = SmartTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
      let outputResult = output.output(text: finalText, target: session.outputTarget)
      session.outputMethod = outputResult.method
      session.outputDelivered = Date()

      if let error = outputResult.error {
        session.errors.append(
          HistoryError(
            phase: .output,
            message: "Failed to deliver text",
            debugDescription: error.localizedDescription
          )
        )
        hudManager.finishFailure(headline: "Delivery failed", message: error.localizedDescription)
        state = .failed(error.localizedDescription)
        lastErrorMessage = error.localizedDescription
        attachFailureDiagnostics(to: session)
        let historyItem = session.buildHistoryItem(finalText: finalText)
        await historyManager.append(historyItem)
      } else {
        session.events.append(
          HistoryEvent(kind: .outputDelivered, description: "Retry output delivered successfully")
        )
        let appName = session.outputTarget?.applicationName
          ?? NSWorkspace.shared.frontmostApplication?.localizedName
        session.destination = appName
        let historyItem = session.buildHistoryItem(finalText: finalText)
        await historyManager.append(historyItem)
        clearRetryData()
        hudManager.finishSuccess(message: "Retry Delivered")
        state = .completed(historyItem)
      }

    case .failure(let error):
      session.postProcessingEnded = Date()
      let friendly = Self.friendlyPostProcessingMessage(
        for: error,
        modelIdentifier: resolvedPostProcessingModel
      )
      session.errors.append(
        HistoryError(
          phase: .postProcessing,
          message: friendly,
          debugDescription: error.localizedDescription
        )
      )
      session.events.append(HistoryEvent(kind: .error, description: friendly))
      hudManager.finishFailure(headline: "Retry post-processing failed", message: friendly, showRetryHint: true)
      state = .failed(friendly)
      lastErrorMessage = friendly
      attachFailureDiagnostics(to: session)
      let historyItem = session.buildHistoryItem(finalText: finalText)
      await historyManager.append(historyItem)
    }

    activeSession = nil
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func reprocessHistoryItem(_ item: HistoryItem) async {
    guard activeSession == nil else { return }
    guard let url = item.audioFileURL else { return }

    state = .processing
    hudManager.beginTranscribing(subheadline: rawTranscriptionSubheadline())

    let session = ActiveSession(
      gesture: .uiButton, hotKeyDescription: item.trigger.hotKeyDescription)
    session.diagnosticContext = makeHistoryDiagnosticContext()
    activeSession = session

    let summary = makeRecordingSummary(from: url, fallbackDuration: item.recordingDuration)
    session.recordingSummary = summary
    session.recordingStarted = summary.startedAt
    session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)
    let reprocessDescription: String
    if item.source == .importedFile {
      reprocessDescription = "Import requested: \(url.lastPathComponent)"
    } else {
      reprocessDescription = "Reprocess requested"
    }

    session.events.append(
      HistoryEvent(kind: .recordingStarted, description: reprocessDescription)
    )

    do {
      session.transcriptionStarted = Date()
      let isLocalTranscription = appSettings.transcriptionMode == .localModel
      session.events.append(
        HistoryEvent(
          kind: .transcriptionSubmitted,
          description: isLocalTranscription ? "Submitting to local model" : "Submitting to batch model"
        )
      )
      let result = try await transcriptionManager.transcribeFile(at: url)
      session.transcriptionEnded = Date()
      session.transcriptionResult = result
      session.modelsUsed.insert(result.modelIdentifier)
      session.modelUsages.append(
        ModelUsage(
          modelIdentifier: result.modelIdentifier,
          phase: isLocalTranscription ? .transcriptionLocal : .transcriptionBatch
        )
      )
      session.events.append(
        HistoryEvent(
          kind: .transcriptionReceived,
          description: isLocalTranscription ? "Local model transcription complete" : "Batch transcription complete"
        )
      )

      if isLocalTranscription {
        session.networkExchanges.append(
          HistoryNetworkExchange(
            url: URL(string: "local://whisperkit")!,
            method: "On-Device",
            requestHeaders: [
              "Model": result.modelIdentifier,
              "Duration": String(format: "%.1fs", result.duration)
            ],
            requestBodyPreview: "Local audio file: \(url.lastPathComponent)",
            responseCode: 200,
            responseHeaders: [:],
            responseBodyPreview: "Transcript: \(String(result.text.prefix(500)))"
          )
        )
      } else if let payload = result.rawPayload {
        session.networkExchanges.append(
          HistoryNetworkExchange(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            method: "POST",
            requestHeaders: [
              "Model": result.modelIdentifier,
              "Content-Type": "application/json",
            ],
            requestBodyPreview: "JSON payload with \(url.lastPathComponent) audio",
            responseCode: 200,
            responseHeaders: [:],
            responseBodyPreview: String(payload.prefix(800))
          )
        )
      }
      if let cost = result.cost {
        session.recordCostFragment(cost)
      }

      // Process voice commands (e.g., "copy pasta" → clipboard content)
      let baseText = textProcessor.process(result.text)
      let lexiconContext = makeLexiconContext(for: baseText, destination: nil)
      let corrections = personalLexicon.apply(to: baseText, context: lexiconContext)
      session.personalCorrections = PersonalLexiconHistorySummary(
        applied: corrections.applied,
        suggestions: corrections.suggestions,
        contextTags: Array(lexiconContext.tags).sorted(),
        destinationApplication: lexiconContext.destinationApplication
      )
      session.lexiconContext = lexiconContext
      var finalText = corrections.transformedText

      if shouldRunPostProcessing() {
        hudManager.beginPostProcessing()
        session.postProcessingStarted = Date()
        guard
          await ensurePostProcessingAPIKeyAvailable(
            for: session,
            message:
              "Post-processing requires an OpenRouter API key. Add one in Settings › API Keys."
          )
        else {
          return
        }
        session.events.append(
          HistoryEvent(kind: .postProcessingSubmitted, description: "Sending to post-processor")
        )
        let postProcessingInput = finalText
        let outcomeResult = await postProcessingManager.process(
          rawText: postProcessingInput,
          context: session.lexiconContext,
          corrections: session.personalCorrections,
          onStreamingUpdate: { [weak self] accumulatedText in
            Task { @MainActor in
              self?.hudManager.updateStreamingText(accumulatedText)
            }
          }
        )
        switch outcomeResult {
        case .success(let outcome):
          session.postProcessingEnded = Date()
          session.postProcessingOutcome = outcome
          finalText = outcome.processed
          if let response = outcome.response {
            session.events.append(
              HistoryEvent(kind: .postProcessingReceived, description: "Post-processing complete")
            )
            if let payload = response.rawPayload {
              session.networkExchanges.append(
                HistoryNetworkExchange(
                  url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                  method: "POST",
                  requestHeaders: ["Model": appSettings.postProcessingModel],
                  requestBodyPreview: postProcessingRequestPreview(
                    systemPrompt: outcome.systemPrompt,
                    rawText: postProcessingInput
                  ),
                  responseCode: 200,
                  responseHeaders: [:],
                  responseBodyPreview: String(payload.prefix(800))
                )
              )
            }
            if let cost = response.cost {
              session.recordCostFragment(cost)
            }
            if !appSettings.postProcessingModel.isEmpty {
              session.modelsUsed.insert(appSettings.postProcessingModel)
              session.modelUsages.append(ModelUsage(modelIdentifier: appSettings.postProcessingModel, phase: .postProcessing))
            }
          } else {
            // Streaming completed without ChatResponse
            session.events.append(
              HistoryEvent(kind: .postProcessingReceived, description: "Post-processing complete (streamed)")
            )
            if !appSettings.postProcessingModel.isEmpty {
              session.modelsUsed.insert(appSettings.postProcessingModel)
              session.modelUsages.append(ModelUsage(modelIdentifier: appSettings.postProcessingModel, phase: .postProcessing))
            }
          }
        case .failure(let error):
          let friendly = Self.friendlyPostProcessingMessage(
            for: error,
            modelIdentifier: appSettings.postProcessingModel
          )
          session.errors.append(
            HistoryError(
              phase: .postProcessing,
              message: friendly,
              debugDescription: error.localizedDescription
            )
          )
          session.events.append(HistoryEvent(kind: .error, description: friendly))
        }
      }

      hudManager.beginDelivering()
      hudManager.finishSuccess(message: "Reprocessed")
      session.events.append(
        HistoryEvent(kind: .outputDelivered, description: "Reprocess stored in history")
      )
      session.outputMethod = .none
      let historyItem = session.buildHistoryItem(finalText: finalText, source: item.source)
      state = .completed(historyItem)
      await historyManager.append(historyItem)

      activeSession = nil
    } catch {
      session.errors.append(
        HistoryError(
          phase: .transcription,
          message: "Reprocess failed",
          debugDescription: error.localizedDescription
        )
      )
      hudManager.finishFailure(message: error.localizedDescription)
      state = .failed(error.localizedDescription)
      attachFailureDiagnostics(to: session)
      let historyItem = session.buildHistoryItem(
        finalText: session.transcriptionResult?.text,
        source: item.source
      )
      await historyManager.append(historyItem)
      activeSession = nil
    }
  }
}
// swiftlint:enable type_body_length
extension MainManager {
  fileprivate func makeRecordingSummary(from url: URL, fallbackDuration: TimeInterval)
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
