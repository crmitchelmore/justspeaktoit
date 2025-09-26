import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
  let settings: AppSettings
  let permissions: PermissionsManager
  let history: HistoryManager
  let hud: HUDManager
  let hotKeys: HotKeyManager
  let audio: AudioFileManager
  let transcription: TranscriptionManager
  let postProcessing: PostProcessingManager
  let secureStorage: SecureAppStorage
  let openRouter: OpenRouterAPIClient
  let main: MainManager
  private let hudPresenter: HUDWindowPresenter

  private(set) var statusBarController: StatusBarController?

  init(
    settings: AppSettings,
    permissions: PermissionsManager,
    history: HistoryManager,
    hud: HUDManager,
    hotKeys: HotKeyManager,
    audio: AudioFileManager,
    transcription: TranscriptionManager,
    postProcessing: PostProcessingManager,
    secureStorage: SecureAppStorage,
    openRouter: OpenRouterAPIClient,
    main: MainManager,
    hudPresenter: HUDWindowPresenter
  ) {
    self.settings = settings
    self.permissions = permissions
    self.history = history
    self.hud = hud
    self.hotKeys = hotKeys
    self.audio = audio
    self.transcription = transcription
    self.postProcessing = postProcessing
    self.secureStorage = secureStorage
    self.openRouter = openRouter
    self.main = main
    self.hudPresenter = hudPresenter
  }

  func installStatusBarIfNeeded(openMainWindow: @escaping () -> Void) {
    guard statusBarController == nil else { return }
    statusBarController = StatusBarController(
      appSettings: settings,
      historyManager: history,
      mainManager: main,
      openMainWindow: openMainWindow
    )
  }
}

@MainActor
enum WireUp {
  static func bootstrap() -> AppEnvironment {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let history = HistoryManager()
    let hud = HUDManager()
    let hotKeys = HotKeyManager(permissionsManager: permissions, appSettings: settings)
    let audio = AudioFileManager(appSettings: settings, permissionsManager: permissions)
    let secureStorage = SecureAppStorage(permissionsManager: permissions, appSettings: settings)
    let openRouter = OpenRouterAPIClient(secureStorage: secureStorage)
    let transcription = TranscriptionManager(
      appSettings: settings,
      permissionsManager: permissions,
      batchClient: RemoteAudioTranscriber(client: openRouter),
      openRouter: openRouter
    )
    let postProcessing = PostProcessingManager(client: openRouter, settings: settings)
    let main = MainManager(
      appSettings: settings,
      permissionsManager: permissions,
      hotKeyManager: hotKeys,
      audioFileManager: audio,
      transcriptionManager: transcription,
      postProcessingManager: postProcessing,
      historyManager: history,
      hudManager: hud
    )
    let hudPresenter = HUDWindowPresenter(manager: hud)

    return AppEnvironment(
      settings: settings,
      permissions: permissions,
      history: history,
      hud: hud,
      hotKeys: hotKeys,
      audio: audio,
      transcription: transcription,
      postProcessing: postProcessing,
      secureStorage: secureStorage,
      openRouter: openRouter,
      main: main,
      hudPresenter: hudPresenter
    )
  }
}
// @Implement: This file should wire up and configure all app dependencies based on the approach laid out in this talk https://www.infoq.com/presentations/8-lines-code-refactoring/
