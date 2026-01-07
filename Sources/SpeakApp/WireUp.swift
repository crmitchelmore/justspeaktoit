import AppKit
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
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
  let main: MainManager
  private let hudPresenter: HUDWindowPresenter

  private(set) var statusBarController: StatusBarController?
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
    main: MainManager,
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
          try? await self.tts.synthesize(text: text)
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
    shortcuts.register(action: .quickVoice1) { [weak self] in
      self?.switchToQuickVoice(1)
    }
    shortcuts.register(action: .quickVoice2) { [weak self] in
      self?.switchToQuickVoice(2)
    }
    shortcuts.register(action: .quickVoice3) { [weak self] in
      self?.switchToQuickVoice(3)
    }
    shortcuts.startMonitoring()
  }

  private func switchToQuickVoice(_ index: Int) {
    let favorites = settings.ttsFavoriteVoices
    let arrayIndex = index - 1
    if arrayIndex < favorites.count {
      settings.defaultTTSVoice = favorites[arrayIndex]
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

@MainActor
enum WireUp {
  static func bootstrap() -> AppEnvironment {
    let settings = AppSettings()
    let permissions = PermissionsManager()
    let history = HistoryManager(flushInterval: settings.historyFlushInterval)
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
    let pronunciationManager = PronunciationManager()
    let postProcessing = PostProcessingManager(
      client: openRouter,
      settings: settings,
      personalLexicon: personalLexicon
    )
    let ttsClients: [TTSProvider: TextToSpeechClient] = [
      .elevenlabs: ElevenLabsClient(secureStorage: secureStorage),
      .openai: OpenAITTSClient(secureStorage: secureStorage),
      .azure: AzureSpeechClient(secureStorage: secureStorage, appSettings: settings),
      .deepgram: DeepgramTTSClient(secureStorage: secureStorage),
      .system: SystemTTSClient(),
    ]
    let tts = TextToSpeechManager(
      appSettings: settings,
      secureStorage: secureStorage,
      clients: ttsClients,
      pronunciationManager: pronunciationManager
    )
    let livePolish = LivePolishManager(client: openRouter, settings: settings)
    let liveTextInserter = LiveTextInserter(
      permissionsManager: permissions,
      appSettings: settings
    )
    let textProcessor = TranscriptionTextProcessor(appSettings: settings)
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
      openRouterClient: openRouter,
      livePolishManager: livePolish,
      liveTextInserter: liveTextInserter,
      textProcessor: textProcessor
    )
    let hudPresenter = HUDWindowPresenter(manager: hud, settings: settings)
    let shortcuts = ShortcutManager(permissionsManager: permissions)

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
      main: main,
      hudPresenter: hudPresenter
    )

    Task { await secureStorage.preloadTrackedSecrets() }

    return environment
  }
}
// @Implement: This file should wire up and configure all app dependencies based on the approach laid out in this talk https://www.infoq.com/presentations/8-lines-code-refactoring/
