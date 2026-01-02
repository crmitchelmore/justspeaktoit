import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
  let settings: AppSettings
  let permissions: PermissionsManager
  let history: HistoryManager
  let hud: HUDManager
  let hotKeys: HotKeyManager
  let audioDevices: AudioInputDeviceManager
  let audio: AudioFileManager
  let transcription: TranscriptionManager
  let postProcessing: PostProcessingManager
  let tts: TextToSpeechManager
  let secureStorage: SecureAppStorage
  let openRouter: OpenRouterAPIClient
  let personalLexicon: PersonalLexiconService
  let main: MainManager
  private let hudPresenter: HUDWindowPresenter

  private(set) var statusBarController: StatusBarController?

  init(
    settings: AppSettings,
    permissions: PermissionsManager,
    history: HistoryManager,
    hud: HUDManager,
    hotKeys: HotKeyManager,
    audioDevices: AudioInputDeviceManager,
    audio: AudioFileManager,
    transcription: TranscriptionManager,
    postProcessing: PostProcessingManager,
    tts: TextToSpeechManager,
    secureStorage: SecureAppStorage,
    openRouter: OpenRouterAPIClient,
    personalLexicon: PersonalLexiconService,
    main: MainManager,
    hudPresenter: HUDWindowPresenter
  ) {
    self.settings = settings
    self.permissions = permissions
    self.history = history
    self.hud = hud
    self.hotKeys = hotKeys
    self.audioDevices = audioDevices
    self.audio = audio
    self.transcription = transcription
    self.postProcessing = postProcessing
    self.tts = tts
    self.secureStorage = secureStorage
    self.openRouter = openRouter
    self.personalLexicon = personalLexicon
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
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let audio = AudioFileManager(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices
    )
    let secureStorage = SecureAppStorage(permissionsManager: permissions, appSettings: settings)
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
    let postProcessing = PostProcessingManager(
      client: openRouter,
      settings: settings,
      personalLexicon: personalLexicon
    )
    let ttsClients: [TTSProvider: TextToSpeechClient] = [
      .elevenlabs: ElevenLabsClient(secureStorage: secureStorage),
      .openai: OpenAITTSClient(secureStorage: secureStorage),
      .azure: AzureSpeechClient(secureStorage: secureStorage, appSettings: settings),
      .system: SystemTTSClient(),
    ]
    let tts = TextToSpeechManager(
      appSettings: settings,
      secureStorage: secureStorage,
      clients: ttsClients
    )
    let main = MainManager(
      appSettings: settings,
      permissionsManager: permissions,
      hotKeyManager: hotKeys,
      audioFileManager: audio,
      transcriptionManager: transcription,
      postProcessingManager: postProcessing,
      historyManager: history,
      hudManager: hud,
      personalLexicon: personalLexicon,
      openRouterClient: openRouter
    )
    let hudPresenter = HUDWindowPresenter(manager: hud)

    let environment = AppEnvironment(
      settings: settings,
      permissions: permissions,
      history: history,
      hud: hud,
      hotKeys: hotKeys,
      audioDevices: audioDevices,
      audio: audio,
      transcription: transcription,
      postProcessing: postProcessing,
      tts: tts,
      secureStorage: secureStorage,
      openRouter: openRouter,
      personalLexicon: personalLexicon,
      main: main,
      hudPresenter: hudPresenter
    )

    Task { await secureStorage.preloadTrackedSecrets() }

    return environment
  }
}
// @Implement: This file should wire up and configure all app dependencies based on the approach laid out in this talk https://www.infoq.com/presentations/8-lines-code-refactoring/
