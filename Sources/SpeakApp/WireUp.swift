import AppKit
import Combine
import Foundation
import SpeakCore
import SpeakSync
import os.log

private let logger = SpeakLogger.logger(category: "WireUp")

// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
final class AppEnvironment: ObservableObject {
  /// Process-wide access point for the App Intents (Shortcuts) surface, set at
  /// bootstrap. Intents can fire before the SwiftUI scene has bootstrapped the
  /// environment (e.g. when Shortcuts launches the app), so it is optional and
  /// intent handlers wait briefly for it — see `AutomationIntents.swift`.
  fileprivate(set) static var shared: AppEnvironment?

  let settings: AppSettings
  let permissions: PermissionsManager
  let history: HistoryManager
  let hud: HUDManager
  let hotKeys: HotKeyManager
  let shortcuts: ShortcutManager
  let audioDevices: AudioInputDeviceManager
  let audio: AudioFileManager
  let transcription: TranscriptionManager
  let postProcessing: PostProcessingManager
  let tts: TextToSpeechManager
  let secureStorage: SecureAppStorage
  let openRouter: OpenRouterAPIClient
  let personalLexicon: PersonalLexiconService
  let pronunciationManager: PronunciationManager
  let livePolish: LivePolishManager
  let liveTextInserter: LiveTextInserter
  let autoCorrectionTracker: AutoCorrectionTracker
  let profiles: DictationProfileStore
  let main: MainManager
  let transportServer: TransportServer
  /// Local automation socket for the `speak` CLI and the bundled MCP server.
  /// Created here (not injected) because it has no dependencies of its own; its
  /// handler is attached in `configureServices` once the managers exist.
  let automationServer = AutomationServer()
  private let hudPresenter: HUDWindowPresenter

  /// Coordinator state for cross-view navigation. When set, MainView selects
  /// the API Keys settings tab and the apiKeySettings view scrolls to the
  /// matching `.id("transcription-<provider.id>")` section.
  @Published var apiKeysScrollTarget: String?
  @Published var sidebarNavigationTarget: SidebarItem?

  /// Bridges HistoryManager mutations to CloudKit history sync. Retained here
  /// because `HistorySyncEngine` only holds its delegate weakly; without this
  /// owner the adapter deallocates after bootstrap and sync stops (#685).
  fileprivate(set) var historySyncAdapter: MacHistorySyncAdapter?

  private(set) var statusBarController: StatusBarController?
  /// Voice-edit controller; created by `installVoiceEdit()` in AppEnvironment+VoiceEdit.
  var voiceEdit: VoiceEditController?
  /// Reopens the main window when the app is running without any visible
  /// window (e.g. menu-bar-only mode). Supplied by the SwiftUI scene.
  var reopenMainWindow: (() -> Void)?
  private var statusBarVisibilityObserver: AnyCancellable?
  /// Product analytics controller — nil when PostHog configuration is absent.
  private(set) var analytics: ProductAnalyticsController?
  var analyticsAvailable: Bool { analytics != nil }
  private var analyticsConsentObserver: AnyCancellable?
  private(set) var menuBarManager: MenuBarManager?
  private(set) var dockMenuManager: DockMenuManager?
  private(set) var servicesProvider: ServicesProvider?
  #if canImport(AppKit)
  @available(macOS 10.12.2, *)
  private(set) var touchBarProvider: TouchBarProvider?
  #endif

  init(
    settings: AppSettings,
    permissions: PermissionsManager,
    history: HistoryManager,
    hud: HUDManager,
    hotKeys: HotKeyManager,
    shortcuts: ShortcutManager,
    audioDevices: AudioInputDeviceManager,
    audio: AudioFileManager,
    transcription: TranscriptionManager,
    postProcessing: PostProcessingManager,
    tts: TextToSpeechManager,
    secureStorage: SecureAppStorage,
    openRouter: OpenRouterAPIClient,
    personalLexicon: PersonalLexiconService,
    pronunciationManager: PronunciationManager,
    livePolish: LivePolishManager,
    liveTextInserter: LiveTextInserter,
    autoCorrectionTracker: AutoCorrectionTracker,
    profiles: DictationProfileStore,
    main: MainManager,
    transportServer: TransportServer,
    hudPresenter: HUDWindowPresenter
  ) {
    self.settings = settings
    self.permissions = permissions
    self.history = history
    self.hud = hud
    self.hotKeys = hotKeys
    self.shortcuts = shortcuts
    self.audioDevices = audioDevices
    self.audio = audio
    self.transcription = transcription
    self.postProcessing = postProcessing
    self.tts = tts
    self.secureStorage = secureStorage
    self.openRouter = openRouter
    self.personalLexicon = personalLexicon
    self.pronunciationManager = pronunciationManager
    self.livePolish = livePolish
    self.liveTextInserter = liveTextInserter
    self.autoCorrectionTracker = autoCorrectionTracker
    self.profiles = profiles
    self.main = main
    self.transportServer = transportServer
    self.hudPresenter = hudPresenter
  }

  /// Sets up the product analytics controller and subscribes to settings changes
  /// so consent state stays in sync with the user's analytics toggle.
  fileprivate func installAnalytics(_ controller: ProductAnalyticsController) {
    analytics = controller
    main.analyticsCapture = { [weak self] event in self?.capture(event) }
    let initiallyEnabled = settings.analyticsEnabled
    // Sync the initial consent state and fire the daily-active-user event.
    Task {
      try? await controller.setConsent(initiallyEnabled ? .optedIn : .optedOut)
      // Fire app_active_daily at most once per calendar day.
      let todayKey = "posthog.lastActiveDailyCaptureDate"
      let today = Calendar.current.startOfDay(for: Date())
      let lastCapture = UserDefaults.standard.object(forKey: todayKey) as? Date
      if initiallyEnabled,
         lastCapture == nil || !Calendar.current.isDate(lastCapture!, inSameDayAs: today) {
        try? await controller.capture(.appActiveDaily)
        UserDefaults.standard.set(today, forKey: todayKey)
      }
    }
    // Keep consent in sync with future settings changes.
    analyticsConsentObserver = settings.$analyticsEnabled
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak controller] enabled in
        guard let controller else { return }
        Task {
          try? await controller.setConsent(enabled ? .optedIn : .optedOut)
          if enabled { try? await controller.capture(.analyticsOptIn(surface: .settings)) }
        }
      }
  }

  /// Capture a product analytics event. No-op when analytics are absent or the
  /// user has not opted in.
  func capture(_ event: ProductAnalyticsEvent) {
    guard let analytics else { return }
    Task { try? await analytics.capture(event) }
  }

  func captureOnboardingCompletedAfterConsent() {
    guard settings.analyticsEnabled, let analytics else { return }
    Task {
      try? await analytics.setConsent(.optedIn)
      try? await analytics.capture(.onboardingCompleted(stepsSkipped: .zero))
    }
  }

  /// Installs the status bar controller and the observer that keeps it in sync
  /// with the visibility settings. Safe to call more than once; it is
  /// idempotent. This is intentionally decoupled from any window lifecycle so
  /// the menu bar access point exists even when no window is on screen (for
  /// example after launching straight into menu-bar-only mode).
  func installStatusBarIfNeeded() {
    if statusBarVisibilityObserver == nil {
      statusBarVisibilityObserver = settings.$appVisibility
        .removeDuplicates()
        .combineLatest(settings.$showStatusBarIconInDockOnly.removeDuplicates())
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in
          self?.updateStatusBarVisibility()
        }
    }
    updateStatusBarVisibility()
  }

  /// Installs or removes the status bar icon to match the current visibility
  /// settings. In Dock Only mode the icon follows `showStatusBarIconInDockOnly`;
  /// in every mode without a Dock icon the status bar icon is always shown so
  /// the app can never end up with no access point.
  private func updateStatusBarVisibility() {
    guard settings.shouldShowStatusBarIcon else {
      statusBarController?.tearDown()
      statusBarController = nil
      return
    }
    guard statusBarController == nil else { return }
    statusBarController = StatusBarController(
      appSettings: settings,
      historyManager: history,
      mainManager: main,
      hotKeyManager: hotKeys,
      openMainWindow: { [weak self] in self?.presentMainWindow() }
    )
  }

  /// Brings the main window to the front, reopening it if the app is running
  /// without any visible window. This is the guaranteed access point behind the
  /// status bar item's "Open Speak…".
  func presentMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
      window.makeKeyAndOrderFront(nil)
      return
    }
    // No visible window (e.g. menu-bar-only mode). Defer past the status menu's
    // event-tracking run loop before asking SwiftUI to reopen the main scene,
    // otherwise the openWindow action can be dropped. Fall back to fronting any
    // window SwiftUI produces.
    DispatchQueue.main.async { [weak self] in
      self?.reopenMainWindow?()
      NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
  }

  func installMenuBar() {
    guard menuBarManager == nil else { return }
    menuBarManager = MenuBarManager(shortcutManager: shortcuts, appSettings: settings)
    menuBarManager?.setupMainMenu()
  }

  func installDockMenu() {
    guard dockMenuManager == nil else { return }
    dockMenuManager = DockMenuManager(historyManager: history)
  }

  func installServices() {
    guard servicesProvider == nil else { return }
    servicesProvider = ServicesProvider(ttsManager: tts, appSettings: settings)
    servicesProvider?.registerServices()
  }

  #if canImport(AppKit)
  @available(macOS 10.12.2, *)
  func installTouchBar() {
    touchBarProvider = TouchBarProvider(mainManager: main, ttsManager: tts, appSettings: settings)
  }
  #endif

  func createDockMenu() -> NSMenu? {
    dockMenuManager?.createDockMenu()
  }

  func configureShortcutHandlers() {
    shortcuts.register(action: .startStopRecording) { [weak self] in
      self?.main.toggleRecordingFromUI()
    }
    shortcuts.register(action: .speakClipboard) { [weak self] in
      guard let self else { return }
      if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
        Task {
          try? await self.tts.synthesize(text: text)
        }
      }
    }
    shortcuts.register(action: .speakSelectedText) { [weak self] in
      guard let self else { return }
      // Get selected text via accessibility or pasteboard simulation
      Task {
        if let text = await self.getSelectedText(), !text.isEmpty {
          _ = try? await self.tts.synthesize(text: text)
        }
      }
    }
    shortcuts.register(action: .pauseResumeTTS) { [weak self] in
      guard let self else { return }
      if self.tts.isPlaying {
        self.tts.pause()
      } else {
        self.tts.resume()
      }
    }
    shortcuts.register(action: .stopTTS) { [weak self] in
      self?.tts.stop()
    }
    shortcuts.register(action: .pasteLastHistoryItem) { [weak self] in self?.pasteLastHistoryItem() }
    shortcuts.register(action: .editSelectionByVoice) { [weak self] in self?.toggleVoiceEdit() }
    registerNavigationShortcutHandlers()
    registerQuickVoiceShortcutHandlers()
    shortcuts.startMonitoring()
  }

  private func registerNavigationShortcutHandlers() {
    let navigationActions: [ShortcutAction: SidebarItem] = [
      .openDashboard: .dashboard,
      .showHistory: .history,
      .openVoiceOutput: .voiceOutput,
      .openCorrections: .corrections,
      .openTroubleshooting: .troubleshooting,
      .openSettings: .settings(.general),
      .openTranscriptionSettings: .settings(.transcription),
      .openPostProcessingSettings: .settings(.postProcessing),
      .openProfilesSettings: .settings(.profiles),
      .openVoiceOutputSettings: .settings(.voiceOutput),
      .openPronunciationSettings: .settings(.pronunciation),
      .openAPIKeysSettings: .settings(.apiKeys),
      .openKeyboardSettings: .settings(.shortcuts),
      .openPermissionsSettings: .settings(.permissions),
      .openAboutSettings: .settings(.about)
    ]
    for (action, item) in navigationActions {
      shortcuts.register(action: action) { [weak self] in
        self?.sidebarNavigationTarget = item
      }
    }
  }

  private func registerQuickVoiceShortcutHandlers() {
    shortcuts.register(action: .quickVoice1) { [weak self] in
      self?.switchToQuickVoice(1)
    }
    shortcuts.register(action: .quickVoice2) { [weak self] in
      self?.switchToQuickVoice(2)
    }
    shortcuts.register(action: .quickVoice3) { [weak self] in
      self?.switchToQuickVoice(3)
    }
  }

  private func getSelectedText() async -> String? {
    // Save current clipboard
    let pasteboard = NSPasteboard.general
    let savedContents = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
      var dict: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          dict[type] = data
        }
      }
      return dict.isEmpty ? nil : dict
    }

    // Simulate Cmd+C to copy selected text
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)

    // Wait for clipboard to update
    try? await Task.sleep(nanoseconds: 100_000_000)

    let selectedText = pasteboard.string(forType: .string)

    // Restore clipboard
    pasteboard.clearContents()
    if let savedContents {
      for itemData in savedContents {
        let item = NSPasteboardItem()
        for (type, data) in itemData {
          item.setData(data, forType: type)
        }
        pasteboard.writeObjects([item])
      }
    }

    return selectedText
  }
}

extension AppEnvironment {
  /// Alias for permissions manager (for API consistency)
  var permissionsManager: PermissionsManager { permissions }

  fileprivate func switchToQuickVoice(_ index: Int) {
    let favorites = settings.ttsFavoriteVoices
    let arrayIndex = index - 1
    if arrayIndex < favorites.count {
      settings.defaultTTSVoice = favorites[arrayIndex]
    }
  }

  /// Pastes the most recent history item's text into the frontmost app,
  /// preferring the post-processed transcription over the raw one. Reuses the
  /// same insertion path as transcription delivery (accessibility or paste,
  /// per the user's configured output method).
  func pasteLastHistoryItem() {
    let text = history.items.first.flatMap { $0.postProcessedTranscription ?? $0.rawTranscription }
    guard let text, PasteTextOutput.hasDeliverableText(text) else {
      hud.finishFailure(
        headline: "Nothing to paste",
        message: "No history items with text yet.",
        displayDuration: 2.5
      )
      return
    }
    let output = SmartTextOutput(permissionsManager: permissions, appSettings: settings)
    let result = output.output(text: text)
    if let error = result.error {
      hud.finishFailure(headline: "Delivery failed", message: error.localizedDescription)
    }
  }
}

// MARK: - Automation

extension AppEnvironment {
  /// Opens the local automation socket when the user has opted in.
  ///
  /// Off by default: the socket lets any process running as this user start the
  /// microphone and read past transcripts, so it stays closed until asked for.
  /// Best-effort at launch — a socket that cannot bind puts the preference back
  /// to off rather than failing startup, exactly as "Send to Mac" does.
  func startAutomationServerIfEnabled() {
    guard settings.enableAutomationServer else { return }
    do {
      try startAutomationServer()
    } catch {
      SpeakLogger.logError(error, context: "Automation socket startup", logger: SpeakLogger.transport)
      settings.enableAutomationServer = false
    }
  }

  /// Opens the socket, wiring it onto the same managers the UI drives.
  ///
  /// Throws rather than logging so the Settings toggle can put the stored
  /// preference back in step with reality.
  func startAutomationServer() throws {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    try automationServer.start(
      handler: AppAutomationHandler(
        main: main,
        history: history,
        transcription: transcription,
        appVersion: version ?? "unknown"
      )
    )
  }

  /// Closes the socket, so nothing local can drive dictation once the user
  /// turns automation off.
  func stopAutomationServer() {
    automationServer.stop()
  }
}

@MainActor
// swiftlint:disable:next type_body_length
enum WireUp {

  // MARK: - Dependency Injection Options

  struct BootstrapOptions {
    var settingsOverride: AppSettings?
    var permissionsOverride: PermissionsManager?
    var keychainServiceOverride: String?
    /// Whether to clear the files a pre-warmed recorder staged in an earlier
    /// run. Only the real app does this: a test bootstrap resolves the user's
    /// own recordings directory, which it must never touch.
    var sweepsStagedLeftovers = true

    static let `default` = BootstrapOptions()
  }

  // swiftlint:disable:next function_body_length
  static func bootstrap(
    options: BootstrapOptions = .default
  ) -> AppEnvironment {
    let settings = options.settingsOverride ?? AppSettings()
    let permissions = options.permissionsOverride
      ?? PermissionsManager()
    let history = HistoryManager(flushInterval: settings.historyFlushInterval)
    let hud = HUDManager(appSettings: settings)
    let hotKeys = HotKeyManager(permissionsManager: permissions, appSettings: settings)
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let audio = AudioFileManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices
    )
    if options.sweepsStagedLeftovers {
      AudioFileManager.scheduleStagedLeftoverSweep(in: settings.recordingsDirectory)
    }
    let secureStorage = SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      keychainService: options.keychainServiceOverride
        ?? "com.github.speakapp.credentials"
    )
    let openRouter = OpenRouterAPIClient(secureStorage: secureStorage)
    let transcription = TranscriptionManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      batchClient: RemoteAudioTranscriber(client: openRouter),
      openRouter: openRouter,
      secureStorage: secureStorage
    )
    let personalLexiconStore = PersonalLexiconStore()
    let personalLexicon = PersonalLexiconService(store: personalLexiconStore)
    let pronunciationManager = PronunciationManager()
    let postProcessing = PostProcessingManager(
      client: openRouter,
      settings: settings,
      personalLexicon: personalLexicon
    )
    let tts = buildTTSManager(settings: settings, secureStorage: secureStorage, pronunciation: pronunciationManager)
    let livePolish = LivePolishManager(client: openRouter, settings: settings)
    let liveTextInserter = LiveTextInserter(
      permissionsManager: permissions,
      appSettings: settings
    )
    let textProcessor = TranscriptionTextProcessor(appSettings: settings)
    let autoCorrectionStore = AutoCorrectionStore()
    let autoCorrectionTracker = AutoCorrectionTracker(
      store: autoCorrectionStore,
      lexiconService: personalLexicon,
      appSettings: settings
    )
    let profiles = DictationProfileStore()
    let main = MainManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioInputDeviceManager: audioDevices,
      hotKeyManager: hotKeys,
      audioFileManager: audio,
      transcriptionManager: transcription,
      postProcessingManager: postProcessing,
      historyManager: history,
      hudManager: hud,
      personalLexicon: personalLexicon,
      openRouterClient: openRouter,
      livePolishManager: livePolish,
      liveTextInserter: liveTextInserter,
      textProcessor: textProcessor,
      autoCorrectionTracker: autoCorrectionTracker,
      profileStore: profiles
    )
    let hudPresenter = HUDWindowPresenter(manager: hud, settings: settings)
    let shortcuts = ShortcutManager(permissionsManager: permissions)

    // Transport server for "Send to Mac" from iOS
    let transportServer = TransportServer()

    let environment = AppEnvironment(
      settings: settings,
      permissions: permissions,
      history: history,
      hud: hud,
      hotKeys: hotKeys,
      shortcuts: shortcuts,
      audioDevices: audioDevices,
      audio: audio,
      transcription: transcription,
      postProcessing: postProcessing,
      tts: tts,
      secureStorage: secureStorage,
      openRouter: openRouter,
      personalLexicon: personalLexicon,
      pronunciationManager: pronunciationManager,
      livePolish: livePolish,
      liveTextInserter: liveTextInserter,
      autoCorrectionTracker: autoCorrectionTracker,
      profiles: profiles,
      main: main,
      transportServer: transportServer,
      hudPresenter: hudPresenter
    )

    configureServices(environment: environment, settings: settings, secureStorage: secureStorage)
    AppEnvironment.shared = environment
    return environment
  }

  // MARK: - Service Configuration

  private static func configureServices(
    environment: AppEnvironment,
    settings: AppSettings,
    secureStorage: SecureAppStorage
  ) {
    environment.installVoiceEdit()

    environment.transportServer.onTranscriptReceived = { _, text in
      Task { @MainActor in
        environment.liveTextInserter.update(with: text)
      }
    }

    // The listener can also fail asynchronously, after start() has already returned
    // (NWListener.start is non-throwing). Handle that the same way as a synchronous
    // failure so the toggle never stays ON with a dead listener behind it — this covers
    // both the launch-time start below and the one in Settings, which share this server.
    environment.transportServer.onFailure = { error in
      Task { @MainActor in
        SpeakLogger.logError(error, context: "Send to Mac listener failed", logger: SpeakLogger.transport)
        settings.enableSendToMac = false
      }
    }

    if settings.enableSendToMac {
      do {
        try environment.transportServer.start()
      } catch {
        // Keep the stored preference honest: leaving the toggle ON while the
        // listener never started would silently drop every "Send to Mac" session.
        SpeakLogger.logError(error, context: "Send to Mac startup", logger: SpeakLogger.transport)
        settings.enableSendToMac = false
      }
    }

    environment.startAutomationServerIfEnabled()

    #if APP_STORE
    NSApp.registerForRemoteNotifications()
    #endif

    let syncAdapter = MacHistorySyncAdapter(historyManager: environment.history)
    environment.historySyncAdapter = syncAdapter
    Task { await syncAdapter.start() }

    Task { await secureStorage.preloadTrackedSecrets() }
    if DistributionChannel.current.supportsEncryptedCloudKitKeySync {
      Task {
        let coreStorage = await secureStorage.coreStorage()
        let keySync = CloudKitKeySync.shared
        await keySync.configure(secureStorage: coreStorage)
        guard await keySync.isAvailable() else { return }
        do {
          try await keySync.syncNow()
        } catch {
          logger.error("CloudKit API-key sync failed: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
    Task {
      await configureDefaultTranscriptionProvider(settings: settings, secureStorage: secureStorage)
    }

    // Analytics
    if let analyticsController = makeAnalyticsController(settings: settings) {
      environment.installAnalytics(analyticsController)
    }

    logger.info("AppEnvironment.bootstrap complete")
  }

  // MARK: - Analytics Factory

  private static func makeAnalyticsController(settings: AppSettings) -> ProductAnalyticsController? {
    #if APP_STORE
    return nil
    #else
    guard DistributionChannel.current == .direct else { return nil }
    guard PostHogProductAnalyticsSink.isConfigured else { return nil }
    let stateURL = (FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.homeDirectoryForCurrentUser)
      .appendingPathComponent("SpeakApp/analytics_state.json")
    let queueURL = stateURL.deletingLastPathComponent().appendingPathComponent("analytics_queue.json")
    let stateStore = FileProductAnalyticsStateStore(fileURL: stateURL)
    let context = buildAnalyticsContext()
    return try? ProductAnalyticsController(
      context: context,
      sink: PostHogProductAnalyticsSink(queueURL: queueURL),
      stateStore: stateStore
    )
    #endif
  }

  private static func buildAnalyticsContext() -> ProductAnalyticsContext {
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let osMajorMinor = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
    let localeCode = Locale.current.language.languageCode?.identifier ?? "en"
    let distributionChannel: AnalyticsDistributionChannel = DistributionChannel.current == .appStore
      ? .macAppStore
      : .direct
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif
    return ProductAnalyticsContext(
      platform: .macOS,
      appVersion: version,
      build: build,
      osMajorMinor: osMajorMinor,
      distributionChannel: distributionChannel,
      localeLanguageCode: localeCode,
      architecture: arch
    )
  }

  // MARK: - TTS Factory

  private static func buildTTSManager(
    settings: AppSettings,
    secureStorage: SecureAppStorage,
    pronunciation: PronunciationManager
  ) -> TextToSpeechManager {
    let clients: [TTSProvider: TextToSpeechClient] = [
      .elevenlabs: ElevenLabsClient(secureStorage: secureStorage),
      .openai: OpenAITTSClient(secureStorage: secureStorage),
      .azure: AzureSpeechClient(secureStorage: secureStorage, appSettings: settings),
      .deepgram: DeepgramTTSClient(secureStorage: secureStorage),
      .soniox: SonioxTTSClient(secureStorage: secureStorage, appSettings: settings),
      .cartesia: CartesiaTTSClient(secureStorage: secureStorage),
      .system: SystemTTSClient()
    ]
    return TextToSpeechManager(
      appSettings: settings,
      secureStorage: secureStorage,
      clients: clients,
      pronunciationManager: pronunciation
    )
  }

  /// Configure the default live transcription model based on available API keys.
  /// Priority: Deepgram > Apple (fallback)
  /// Called on app launch and after onboarding completes.
  static func configureDefaultTranscriptionProvider(
    settings: AppSettings,
    secureStorage: SecureAppStorage
  ) async {
    // Only configure if the user has never chosen a live transcription model.
    // Checking the stored choice (rather than "is it still Apple?") means a
    // deliberate Apple Speech selection survives every launch.
    guard !settings.hasExplicitLiveTranscriptionModelChoice else {
      logger.info("User has chosen a transcription model, skipping auto-config")
      return
    }

    // Check for Deepgram API key
    let hasDeepgramKey = await secureStorage.hasSecret(identifier: "deepgram.apiKey")

    if hasDeepgramKey {
      await MainActor.run {
        // Re-check after the keychain await: the user may have chosen a model
        // while this task was suspended, and that choice must win.
        guard !settings.hasExplicitLiveTranscriptionModelChoice else {
          logger.info("User chose a transcription model during auto-config, skipping")
          return
        }
        settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
        logger.info("Deepgram API key found, setting as default transcription provider")
      }
    } else {
      logger.info("No Deepgram API key found, using Apple on-device transcription as default")
    }
  }
}
// @Implement: This file wires up and configures app dependencies.
// swiftlint:enable file_length
