import SpeakCore
import AppKit
@preconcurrency import AVFoundation
import Foundation
import os.log

// MARK: - Switching Live Transcriber

struct LiveTranscriptionControllerReusePolicy {
  static let idleResetThreshold: TimeInterval = 10 * 60

  static func shouldResetControllers(
    invalidateBeforeNextStart: Bool,
    lastStopDate: Date?,
    now: Date
  ) -> Bool {
    guard !invalidateBeforeNextStart else { return true }
    guard let lastStopDate else { return false }
    return now.timeIntervalSince(lastStopDate) >= idleResetThreshold
  }
}

// Routes to appropriate live transcription controller based on selected model.
// swiftlint:disable:next type_body_length
final class SwitchingLiveTranscriber: LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate? {
    didSet {
      applyDelegateAndConfiguration()
    }
  }

  var isRunning: Bool {
    activeController?.isRunning ?? false
  }

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private let nowProvider: () -> Date
  private var activeController: (any LiveTranscriptionController)?
  private var controllers: ControllerSet
  private var currentLanguage: String?
  private var currentModel: String?
  private var invalidateBeforeNextStart: Bool = false
  private var lastStopDate: Date?
  private var willSleepObserver: NSObjectProtocol?
  private var didWakeObserver: NSObjectProtocol?

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    secureStorage: SecureAppStorage,
    nowProvider: @escaping () -> Date = Date.init
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.secureStorage = secureStorage
    self.nowProvider = nowProvider
    controllers = ControllerSet(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    applyDelegateAndConfiguration()
    startObservingLifecycle()
  }

  deinit {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    if let willSleepObserver {
      notificationCenter.removeObserver(willSleepObserver)
    }
    if let didWakeObserver {
      notificationCenter.removeObserver(didWakeObserver)
    }
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
    print("[SwitchingLiveTranscriber] Configured with model: \(model)")
    applyDelegateAndConfiguration()
  }

  func start() async throws {
    let model = currentModel ?? appSettings.liveTranscriptionModel
    print("[SwitchingLiveTranscriber] Starting with model: \(model)")
    if shouldResetControllersBeforeStart(at: nowProvider()) {
      print("[SwitchingLiveTranscriber] Resetting cached live controllers before start")
      resetControllers()
    }

    let controller = controller(for: model)
    activeController = controller
    do {
      try await controller.start()
      invalidateBeforeNextStart = false
    } catch {
      if model == AppleLocalModels.speechTranscriberModelID {
        print(
          "[SwitchingLiveTranscriber] SpeechAnalyzer failed "
            + "(\(error.localizedDescription)); using legacy Apple Speech")
        let nativeController = controllers.native
        nativeController.configure(
          language: currentLanguage,
          model: AppleLocalModels.legacySpeechModelID
        )
        activeController = nativeController
        do {
          try await nativeController.start()
          invalidateBeforeNextStart = false
          return
        } catch {
          activeController = nil
          invalidateBeforeNextStart = true
          throw error
        }
      }
      activeController = nil
      invalidateBeforeNextStart = true
      throw error
    }
  }

  func stop() async {
    print("[SwitchingLiveTranscriber] Stopping...")
    await activeController?.stop()
    activeController = nil
    lastStopDate = nowProvider()
  }

  func controller(for model: String) -> any LiveTranscriptionController {
    if model == AppleLocalModels.speechTranscriberModelID {
      return controllers.speechAnalyzer
    }
    if let route = controllerRoutes.first(where: { model.hasPrefix($0.prefix) }) {
      return route.controller
    }
    // SwitchingLiveTranscriber only routes live transcription models, and
    // OpenAI's only live transcription transport is the Realtime WebSocket
    // API. So any openai/* live model is handled by the realtime controller.
    if model.hasPrefix("openai/") { return controllers.openAIRealtime }
    if FluidAudioParakeetModel.matches(model) { return controllers.fluidAudio }
    if WhisperKitStreamingModel.matches(model) { return controllers.whisperKit }
    #if !APP_STORE
    if model.hasPrefix("local/streaming/") { return controllers.sherpaOnnx }
    #else
    if model.hasPrefix("local/streaming/") { return controllers.unsupportedLocalLive }
    #endif
    if ModelRouting.family(for: model).isDownloadedLocal { return controllers.unsupportedLocalLive }
    return controllers.native
  }

  private var controllerRoutes: [(prefix: String, controller: any LiveTranscriptionController)] {
    [
      ("assemblyai/", controllers.assemblyAI),
      ("deepgram/", controllers.deepgram),
      ("modulate/", controllers.modulate),
      ("elevenlabs/", controllers.elevenlabs),
      ("soniox/", controllers.soniox),
      ("speechmatics/", controllers.speechmatics),
      ("cartesia/", controllers.cartesia),
      ("gladia/", controllers.gladia),
      ("xai/", controllers.sharedClient)
    ]
  }

  private func applyDelegateAndConfiguration() {
    let model = currentModel ?? appSettings.liveTranscriptionModel
    for controller in controllers.all {
      controller.delegate = delegate
      controller.configure(language: currentLanguage, model: model)
    }
  }

  private func shouldResetControllersBeforeStart(at now: Date) -> Bool {
    LiveTranscriptionControllerReusePolicy.shouldResetControllers(
      invalidateBeforeNextStart: invalidateBeforeNextStart,
      lastStopDate: lastStopDate,
      now: now
    )
  }

  private func resetControllers() {
    activeController = nil
    controllers = ControllerSet(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    invalidateBeforeNextStart = false
    lastStopDate = nil
    applyDelegateAndConfiguration()
  }

  private func startObservingLifecycle() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    willSleepObserver = notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.markControllersStale()
      }
    }
    didWakeObserver = notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.markControllersStale()
      }
    }
  }

  /// Whether the controller cache has been marked stale and will reset on next start.
  var isCacheStale: Bool { invalidateBeforeNextStart }

  @MainActor
  func markControllersStale() {
    invalidateBeforeNextStart = true
  }

  /// The single place live controllers are constructed. `init` and
  /// `resetControllers` both build one of these so the two paths cannot drift.
  @MainActor
  private struct ControllerSet {
    let native: NativeOSXLiveTranscriber
    let speechAnalyzer: AppleSpeechAnalyzerLiveController
    let deepgram: DeepgramLiveController
    let modulate: ModulateLiveController
    let assemblyAI: AssemblyAILiveController
    let elevenlabs: ElevenLabsLiveController
    let soniox: SonioxLiveController
    let speechmatics: SpeechmaticsLiveController
    let cartesia: CartesiaLiveController
    let gladia: GladiaLiveController
    let openAIRealtime: OpenAIRealtimeLiveController
    let sharedClient: SharedClientLiveController
    let fluidAudio: FluidAudioParakeetLiveController
    let whisperKit: WhisperKitLiveController
    #if !APP_STORE
    let sherpaOnnx: SherpaOnnxLiveController
    #endif
    let unsupportedLocalLive: UnsupportedLocalLiveTranscriber

    // swiftlint:disable:next function_body_length
    init(
      appSettings: AppSettings,
      permissionsManager: PermissionsManager,
      audioDeviceManager: AudioInputDeviceManager,
      secureStorage: SecureAppStorage
    ) {
      native = NativeOSXLiveTranscriber(
        permissionsManager: permissionsManager,
        appSettings: appSettings,
        audioDeviceManager: audioDeviceManager
      )
      speechAnalyzer = AppleSpeechAnalyzerLiveController(
        permissionsManager: permissionsManager,
        appSettings: appSettings,
        audioDeviceManager: audioDeviceManager
      )
      deepgram = DeepgramLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      modulate = ModulateLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      assemblyAI = AssemblyAILiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      elevenlabs = ElevenLabsLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      soniox = SonioxLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      speechmatics = SpeechmaticsLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      cartesia = CartesiaLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      gladia = GladiaLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      openAIRealtime = OpenAIRealtimeLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      sharedClient = SharedClientLiveController(
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        secureStorage: secureStorage
      )
      fluidAudio = FluidAudioParakeetLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        modelManager: FluidAudioModelManager.shared
      )
      whisperKit = WhisperKitLiveController(
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        modelManager: LocalModelManager.shared
      )
      #if !APP_STORE
      sherpaOnnx = SherpaOnnxLiveController(
        appSettings: appSettings,
        permissionsManager: permissionsManager,
        audioDeviceManager: audioDeviceManager,
        runtimeManager: SherpaOnnxRuntimeManager.shared
      )
      #endif
      unsupportedLocalLive = UnsupportedLocalLiveTranscriber()
    }

    var all: [any LiveTranscriptionController] {
      var controllers: [any LiveTranscriptionController] = [
        native,
        speechAnalyzer,
        deepgram,
        modulate,
        assemblyAI,
        elevenlabs,
        soniox,
        speechmatics,
        cartesia,
        gladia,
        openAIRealtime,
        sharedClient,
        whisperKit,
        fluidAudio
      ]
      #if !APP_STORE
      controllers.append(sherpaOnnx)
      #endif
      controllers.append(unsupportedLocalLive)
      return controllers
    }
  }
}
