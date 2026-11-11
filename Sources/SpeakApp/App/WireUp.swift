import AppKit
import Combine
import Foundation
import SpeakCore
import SpeakSync
import os.log

private let logger = SpeakLogger.logger(category: "WireUp")

// swiftlint:disable file_length

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

  /// Bridges HistoryManager mutations to CloudKit history sync. Retained here
  /// because `HistorySyncEngine` only holds its delegate weakly; without this
  /// owner the adapter deallocates after bootstrap and sync stops (#685).
  fileprivate(set) var historySyncAdapter: MacHistorySyncAdapter?
  /// Compare Models rounds and their CloudKit bridge (issue #1101). Created
  /// at bootstrap so rounds judged on another Mac arrive before the section
  /// is opened, and retained here for the same reason as the history adapter.
  let comparisonRounds: ComparisonRoundStore
  fileprivate(set) var comparisonSyncAdapter: MacComparisonSyncAdapter?
  /// Owned here rather than by the Settings view so leaving the section
  /// mid-capture cannot deallocate a controller that still holds the
  /// microphone. Leaving cancels an in-flight capture (`CompareModelsView`
  /// `onDisappear`); a round awaiting judgement is reattached on return.
  lazy var compareModels = CompareModelsController(environment: self, store: comparisonRounds)
  /// Posts and acts on notifications for transcripts arriving from an iPhone
  /// or Apple Watch (issue #1007).
  fileprivate(set) var remoteTranscriptDelivery: RemoteTranscriptDelivery?

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
  /// Product analytics controller — nil when PostHog configuration is absent.
  private(set) var analytics: ProductAnalyticsController?
  #if !APP_STORE
  fileprivate(set) var analyticsPrivacyControls: AnalyticsPrivacyControls?
  #endif
  var analyticsAvailable: Bool { analytics != nil }
  private var analyticsConsentObserver: AnyCancellable?

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

  /// Sets up the product analytics controller and subscribes to settings changes
  /// so consent state stays in sync with the user's analytics toggle.
  fileprivate func installAnalytics(_ controller: ProductAnalyticsController) {
    analytics = controller
    main.analyticsCapture = { [weak self] event in self?.capture(event) }
    let initiallyEnabled = settings.analyticsEnabled
    // Sync the initial consent state and fire the daily-active-user event.
    Task {
      try? await controller.setConsent(initiallyEnabled ? .optedIn : .optedOut)
      #if !APP_STORE
      await analyticsPrivacyControls?.refresh()
      #endif
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
      .sink { [weak controller, weak self] enabled in
        guard let controller else { return }
        #if !APP_STORE
        self?.analyticsPrivacyControls?.invalidate()
        #endif
        Task {
          try? await controller.setConsent(enabled ? .optedIn : .optedOut)
          #if !APP_STORE
          await self?.analyticsPrivacyControls?.refresh()
          #endif
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

  /// Opens the main window on the General settings tab. This backs the status
  /// bar item's "Settings…"; the navigation target is set first so a window
  /// SwiftUI has yet to create still receives the selection when it subscribes.
  func presentSettings() {
    sidebarNavigationTarget = .settings(.general)
    presentMainWindow()
  }

  /// Opens the "System resources in use" card, which lives on the Permissions page.
  func presentSystemResourcesStatus() {
    sidebarNavigationTarget = .settings(.permissions)
    presentMainWindow()
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

  /// Installs the status bar and keeps it in step with the visibility settings.
  func installStatusBarIfNeeded() {
    SystemResourceMonitor.shared.start(environment: self)
    chrome.installStatusBarIfNeeded()
  }
  func installMenuBar() { chrome.installMenuBar() }
  func installDockMenu() { chrome.installDockMenu() }
  func installServices() { chrome.installServices() }
  #if canImport(AppKit)
  @available(macOS 10.12.2, *)
  func installTouchBar() { chrome.installTouchBar() }
  #endif
  func createDockMenu() -> NSMenu? { chrome.createDockMenu() }

  func captureOnboardingCompletedAfterConsent() {
    guard settings.analyticsEnabled, let analytics else { return }
    Task {
      try? await analytics.setConsent(.optedIn)
      try? await analytics.capture(.onboardingCompleted(stepsSkipped: .zero))
    }
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

  // MARK: - Dependency Injection Options

  struct BootstrapOptions {
    var settingsOverride: AppSettings?
    var permissionsOverride: PermissionsManager?
    /// Opens an isolated credential vault under this service instead of the
    /// user's. It has no legacy predecessor and never joins API-key sync, so a
    /// test or launch profile cannot read, copy or sync the user's keys.
    var keychainServiceOverride: String?
    /// Whether to clear the files a pre-warmed recorder staged in an earlier
    /// run. Only the real app does this: staging lives in the user's temporary
    /// folder, which a test or launch profile shares with the real app.
    var sweepsStagedLeftovers = true
    /// Resolves Application Support for history, the personal lexicon,
    /// corrections, Compare Models rounds and analytics state.
    var fileManager: FileManager = .default
    /// Preferences for the stores that do not read `AppSettings`: profiles,
    /// pronunciation, shortcuts, synced-history bookkeeping and speech usage.
    var defaults: UserDefaults = .standard
    /// Process-wide services started once the graph is wired.
    var integrations: Integrations = .live

    static let `default` = BootstrapOptions()

    /// The credential vault this bootstrap opens.
    var credentialStorage: SecureStorageConfiguration {
      keychainServiceOverride.map(SecureAppStorage.isolatedConfiguration(service:))
        ?? SecureAppStorage.productionConfiguration
    }

    /// Whether this bootstrap starts encrypted API-key sync on `channel`. Only
    /// the user's own vault may: the shared sync pairs it with this Mac's sync
    /// state and the user's private CloudKit database.
    func startsCredentialKeySync(on channel: DistributionChannel) -> Bool {
      keychainServiceOverride == nil && channel.supportsEncryptedCloudKitKeySync
    }
  }

  /// The services a bootstrap reaches beyond the app's own objects. The app
  /// uses `.live`; a test injects its own so bootstrap never syncs the
  /// developer's iCloud account, registers for or posts notifications, or
  /// sends analytics.
  struct Integrations {
    /// Starts CloudKit history and Compare Models sync, and remote-transcript
    /// delivery, which registers its notification actions and re-runs sync
    /// on wake and activation.
    var startCloudSync: @MainActor (MacHistorySyncAdapter, MacComparisonSyncAdapter, RemoteTranscriptDelivery) -> Void
    /// Builds product analytics over the bootstrap's storage, or nil when absent.
    var makeAnalytics: @MainActor (AppSettings, FileManager) -> AnalyticsServices?

    static let live = Integrations(
      startCloudSync: { history, comparisons, remoteTranscripts in
        #if APP_STORE
        NSApp.registerForRemoteNotifications()
        #endif
        remoteTranscripts.start()
        Task {
          await history.start()
          // After the history engine, which owns zone creation for the shared zone.
          await comparisons.start()
        }
      },
      makeAnalytics: WireUp.makeAnalyticsController(settings:fileManager:)
    )
  }

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
    attachCloudSync(to: environment, settings: settings, options: options)

    Task { await secureStorage.preloadTrackedSecrets() }
    if options.startsCredentialKeySync(on: .current) {
      startCredentialKeySync(secureStorage: secureStorage)
    }
    Task {
      await configureDefaultTranscriptionProvider(settings: settings, secureStorage: secureStorage)
    }

    // Analytics
    if let analyticsServices = options.integrations.makeAnalytics(settings, options.fileManager) {
      #if !APP_STORE
      environment.analyticsPrivacyControls = analyticsServices.privacyControls
      #endif
      environment.installAnalytics(analyticsServices.controller)
    }

    logger.info("AppEnvironment.bootstrap complete")
  }

  /// CloudKit History and Compare Models sync, plus notifications for
  /// transcripts arriving from an iPhone or Apple Watch (#1007).
  private static func attachCloudSync(
    to environment: AppEnvironment,
    settings: AppSettings,
    options: BootstrapOptions
  ) {
    let syncAdapter = MacHistorySyncAdapter(historyManager: environment.history, defaults: options.defaults)
    environment.historySyncAdapter = syncAdapter
    // Phone and watch captures arriving through CloudKit history sync (#1007).
    let remoteTranscripts = RemoteTranscriptDelivery(
      settings: settings,
      paste: { text in
        SmartTextOutput(permissionsManager: environment.permissions, appSettings: settings)
          .output(text: text, target: nil)
      },
      // A notification stays actionable across a relaunch; its identifier is
      // the History entry id, so the durable local entry answers the action
      // even when the posting process is long gone.
      transcriptForEntry: { [weak history = environment.history] entryID in
        guard let item = history?.items.first(where: { $0.id == entryID }) else { return nil }
        return item.postProcessedTranscription ?? item.rawTranscription
      }
    )
    environment.remoteTranscriptDelivery = remoteTranscripts
    syncAdapter.onRemoteEntryArrived = { [weak remoteTranscripts] entry, isNew in
      remoteTranscripts?.handle(entry: entry, isNewToThisMac: isNew)
    }
    let comparisonSync = MacComparisonSyncAdapter(store: environment.comparisonRounds)
    environment.comparisonSyncAdapter = comparisonSync
    options.integrations.startCloudSync(syncAdapter, comparisonSync, remoteTranscripts)

  }

  // MARK: - Credential Vault Factory

  /// Opens the credential vault a bootstrap with `options` uses.
  static func buildSecureStorage(
    options: BootstrapOptions,
    settings: AppSettings,
    permissions: PermissionsManager
  ) -> SecureAppStorage {
    SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      configuration: options.credentialStorage
    )
  }

}
// @Implement: This file wires up and configures app dependencies.
// swiftlint:enable file_length
