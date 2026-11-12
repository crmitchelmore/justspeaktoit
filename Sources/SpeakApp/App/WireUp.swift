import AppKit
import Combine
import Foundation
import SpeakCore
import SpeakSync
import os.log

private let logger = SpeakLogger.logger(category: "WireUp")

// The dependency container: one stored property, one initialiser parameter and
// one assignment per service, so it grows by three lines whenever the app gains
// one. Splitting it would only move the list somewhere else.
@MainActor
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
  let paidAccess: PaidAccessManager
  let personalLexicon: PersonalLexiconService
  let pronunciationManager: PronunciationManager
  let livePolish: LivePolishManager
  let liveTextInserter: LiveTextInserter
  let autoCorrectionTracker: AutoCorrectionTracker
  let profiles: DictationProfileStore
  let main: MainManager
  /// Record-control state for the main window; see `RecordingControlModel`.
  lazy var recordingControl = RecordingControlModel(main: main)
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
  /// Settings search entry to reveal once its page is selected; consumed by
  /// SettingsView, which scrolls to and highlights the matching card.
  @Published var settingsSearchTarget: String?
  @Published var isSettingsSearchPresented = false

  /// CloudKit sync and remote-transcript delivery; see `AppCloudSync`.
  fileprivate(set) var cloudSync: AppCloudSync?
  var historySyncAdapter: MacHistorySyncAdapter? { cloudSync?.history }
  /// Compare Models rounds and their CloudKit bridge (issue #1101). Created
  /// at bootstrap so rounds judged on another Mac arrive before the section
  /// is opened.
  let comparisonRounds: ComparisonRoundStore
  var comparisonSyncAdapter: MacComparisonSyncAdapter? { cloudSync?.comparisons }
  /// Owned here rather than by the Settings view so leaving the section
  /// mid-capture cannot deallocate a controller that still holds the
  /// microphone. Leaving cancels an in-flight capture (`CompareModelsView`
  /// `onDisappear`); a round awaiting judgement is reattached on return.
  lazy var compareModels = CompareModelsController(environment: self, store: comparisonRounds)
  /// Posts and acts on notifications for transcripts arriving from an iPhone
  /// or Apple Watch (issue #1007).
  var remoteTranscriptDelivery: RemoteTranscriptDelivery? { cloudSync?.remoteTranscripts }

  /// Status bar, menu bar, Dock menu, Services and Touch Bar; see `AppChrome`.
  private(set) lazy var chrome = AppChrome(
    settings: settings,
    history: history,
    main: main,
    hotKeys: hotKeys,
    shortcuts: shortcuts,
    tts: tts,
    openMainWindow: { [weak self] in self?.presentMainWindow() },
    openSettings: { [weak self] in self?.presentSettings() },
    openStatus: { [weak self] in self?.presentSystemResourcesStatus() }
  )
  var statusBarController: StatusBarController? { chrome.statusBarController }
  /// Voice-edit controller; created by `installVoiceEdit()` in AppEnvironment+VoiceEdit.
  var voiceEdit: VoiceEditController?
  /// Reopens the main window when the app is running without any visible
  /// window (e.g. menu-bar-only mode). Supplied by the SwiftUI scene.
  var reopenMainWindow: (() -> Void)?
  /// Product analytics — nil when PostHog configuration is absent.
  private var analytics: AppAnalytics?
  #if !APP_STORE
  var analyticsPrivacyControls: AnalyticsPrivacyControls? { analytics?.privacyControls }
  #endif
  var analyticsAvailable: Bool { analytics != nil }

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
    paidAccess: PaidAccessManager,
    personalLexicon: PersonalLexiconService,
    pronunciationManager: PronunciationManager,
    livePolish: LivePolishManager,
    liveTextInserter: LiveTextInserter,
    autoCorrectionTracker: AutoCorrectionTracker,
    profiles: DictationProfileStore,
    main: MainManager,
    transportServer: TransportServer,
    hudPresenter: HUDWindowPresenter,
    comparisonRounds: ComparisonRoundStore
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
    self.paidAccess = paidAccess
    self.personalLexicon = personalLexicon
    self.pronunciationManager = pronunciationManager
    self.livePolish = livePolish
    self.liveTextInserter = liveTextInserter
    self.autoCorrectionTracker = autoCorrectionTracker
    self.profiles = profiles
    self.main = main
    self.transportServer = transportServer
    self.hudPresenter = hudPresenter
    self.comparisonRounds = comparisonRounds
  }

  /// Installs product analytics and keeps its consent in step with the
  /// user's analytics toggle.
  fileprivate func installAnalytics(_ analytics: AppAnalytics) {
    self.analytics = analytics
    main.analyticsCapture = { [weak self] event in self?.capture(event) }
    analytics.start(settings: settings)
  }

  /// Capture a product analytics event. No-op when analytics are absent or the
  /// user has not opted in.
  func capture(_ event: ProductAnalyticsEvent) {
    analytics?.capture(event)
  }

  func captureOnboardingCompletedAfterConsent() {
    guard settings.analyticsEnabled, let analytics else { return }
    analytics.captureOnboardingCompletedAfterConsent()
  }

}

extension AppEnvironment {
  /// Alias for permissions manager (for API consistency)
  var permissionsManager: PermissionsManager { permissions }

  /// Makes every service durable before AppKit lets the process exit.
  ///
  /// The history sync adapter coalesces its synced-ID bookkeeping behind a
  /// short window, so a quit inside that window would otherwise drop the
  /// pending write and leave the next launch working from a stale set (#851).
  /// The flush runs first and synchronously — termination does not wait for
  /// work that is merely scheduled.
  func prepareForTermination() async {
    historySyncAdapter?.flushPendingSyncedIDs()
    await main.prepareForTermination()
    await AppSettings.SystemDependencies.drainLoginItemChanges()
  }

}

@MainActor
enum WireUp {

  // swiftlint:disable:next function_body_length
  static func bootstrap(
    options suppliedOptions: BootstrapOptions = .default
  ) -> AppEnvironment {
    #if DEBUG
    let profile = CoreJourneyLaunchProfile.current
    let options = profile?.bootstrapOptions() ?? suppliedOptions
    #else
    let options = suppliedOptions
    #endif
    let fileManager = options.fileManager
    let defaults = options.defaults
    let settings = options.settingsOverride ?? AppSettings()
    let permissions = options.permissionsOverride
      ?? PermissionsManager()
    let history = HistoryManager(fileManager: fileManager, flushInterval: settings.historyFlushInterval)
    let hud = HUDManager(appSettings: settings)
    let hotKeys = HotKeyManager(permissionsManager: permissions, appSettings: settings)
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let audio = AudioFileManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      captureSource: captureSourceForLaunch()
    )
    if options.sweepsStagedLeftovers {
      RecordingFiles.scheduleStagedLeftoverSweep(in: settings.recordingsDirectory)
    }
    let secureStorage = buildSecureStorage(options: options, settings: settings, permissions: permissions)
    #if DEBUG
    let openRouter: OpenRouterAPIClient
    if let profile, profile.runsBatchJourney {
      openRouter = profile.makeFixtureClient()
    } else {
      openRouter = OpenRouterAPIClient(secureStorage: secureStorage)
    }
    #else
    let openRouter = OpenRouterAPIClient(secureStorage: secureStorage)
    #endif

    let (paidAccess, routedClient) = makePaidAccessRouting(
      openRouter: openRouter, secureStorage: secureStorage, settings: settings
    )

    let transcription = TranscriptionManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      batchClient: RemoteAudioTranscriber(client: routedClient),
      openRouter: openRouter,
      secureStorage: secureStorage,
      controllerOverride: liveControllerOverrideForLaunch()
    )
    let personalLexiconStore = PersonalLexiconStore(fileManager: fileManager)
    let personalLexicon = PersonalLexiconService(store: personalLexiconStore)
    let pronunciationManager = PronunciationManager(defaults: defaults)
    let postProcessing = PostProcessingManager(
      client: routedClient,
      settings: settings,
      personalLexicon: personalLexicon
    )
    let tts = buildTTSManager(
      settings: settings,
      secureStorage: secureStorage,
      pronunciation: pronunciationManager,
      defaults: defaults
    )
    let livePolish = LivePolishManager(client: openRouter, settings: settings)
    let liveTextInserter = LiveTextInserter(
      permissionsManager: permissions,
      appSettings: settings
    )
    let textProcessor = TranscriptionTextProcessor(appSettings: settings)
    let autoCorrectionStore = AutoCorrectionStore(fileManager: fileManager)
    let autoCorrectionTracker = AutoCorrectionTracker(
      store: autoCorrectionStore,
      lexiconService: personalLexicon,
      appSettings: settings
    )
    let profiles = DictationProfileStore(defaults: defaults)
    let main = MainManager(
      appSettings: settings,
      capture: SessionCaptureServices(
        permissions: permissions, devices: audioDevices, hotKeys: hotKeys, audioFiles: audio, profiles: profiles
      ),
      transcriptionManager: transcription,
      text: SessionTextServices(
        textProcessor: textProcessor, personalLexicon: personalLexicon, postProcessing: postProcessing,
        livePolish: livePolish, liveTextInserter: liveTextInserter, autoCorrectionTracker: autoCorrectionTracker
      ),
      historyManager: history,
      hudManager: hud,
      connectionPrewarmer: ConnectionPrewarmer(settings: settings, permissions: permissions, client: openRouter)
    )
    let hudPresenter = HUDWindowPresenter(manager: hud, settings: settings)
    let shortcuts = ShortcutManager(permissionsManager: permissions, defaults: defaults)

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
      paidAccess: paidAccess,
      personalLexicon: personalLexicon,
      pronunciationManager: pronunciationManager,
      livePolish: livePolish,
      liveTextInserter: liveTextInserter,
      autoCorrectionTracker: autoCorrectionTracker,
      profiles: profiles,
      main: main,
      transportServer: transportServer,
      hudPresenter: hudPresenter,
      comparisonRounds: ComparisonRoundStore(fileManager: fileManager)
    )

    configureServices(environment: environment, settings: settings, secureStorage: secureStorage, options: options)
    AppEnvironment.shared = environment
    return environment
  }

  private static func captureSourceForLaunch() -> (any RecordingCaptureSource)? {
    #if DEBUG
    if let profile = CoreJourneyLaunchProfile.current, profile.runsBatchJourney {
      return profile.makeCaptureSource()
    }
    #endif
    return nil
  }

  private static func liveControllerOverrideForLaunch() -> ((String) -> any LiveTranscriptionController)? {
    #if DEBUG
    if let profile = CoreJourneyLaunchProfile.current, profile.runsBatchJourney {
      return profile.makeLiveControllerOverride()
    }
    #endif
    return nil
  }

  // MARK: - Service Configuration
  private static func configureServices(
    environment: AppEnvironment,
    settings: AppSettings,
    secureStorage: SecureAppStorage,
    options: BootstrapOptions
  ) {
    #if DEBUG
    // Construct production managers and UI, but never preload credentials,
    // sync accounts, open listeners, or install voice-edit capture in this check.
    if let profile = CoreJourneyLaunchProfile.current {
        profile.startHotKeyProbe(manager: environment.hotKeys, main: environment.main)
      logger.info("AppEnvironment.bootstrap complete (isolated UI launch profile)")
      return
    }
    #endif
    environment.installVoiceEdit()

    restorePaidAccessEntitlement(in: environment)

    configureSendToMac(environment: environment, settings: settings)
    environment.startAutomationServerIfEnabled()
    let cloudSync = AppCloudSync(
      history: environment.history, comparisonRounds: environment.comparisonRounds,
      permissions: environment.permissions, settings: settings, defaults: options.defaults
    )
    environment.cloudSync = cloudSync
    options.integrations.startCloudSync(cloudSync.history, cloudSync.comparisons, cloudSync.remoteTranscripts)

    Task { await secureStorage.preloadTrackedSecrets() }
    if options.startsCredentialKeySync(on: .current) {
      startCredentialKeySync(secureStorage: secureStorage)
    }
    Task {
      await configureDefaultTranscriptionProvider(settings: settings, secureStorage: secureStorage)
    }

    // Analytics
    if let analyticsServices = options.integrations.makeAnalytics(settings, options.fileManager) {
      environment.installAnalytics(AppAnalytics(services: analyticsServices))
    }

    logger.info("AppEnvironment.bootstrap complete")
  }
}
// @Implement: This file wires up and configures app dependencies.
