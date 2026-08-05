// swiftlint:disable file_length
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
  private var nativeController: NativeOSXLiveTranscriber
  private var speechAnalyzerController: AppleSpeechAnalyzerLiveController
  private var deepgramController: DeepgramLiveController
  private var modulateController: ModulateLiveController
  private var assemblyAIController: AssemblyAILiveController
  private var elevenlabsController: ElevenLabsLiveController
  private var sonioxController: SonioxLiveController
  private var speechmaticsController: SpeechmaticsLiveController
  private var cartesiaController: CartesiaLiveController
  private var gladiaController: GladiaLiveController
  private var openAIRealtimeController: OpenAIRealtimeLiveController
  private var sharedClientController: SharedClientLiveController
  private var fluidAudioController: FluidAudioParakeetLiveController
  private var whisperKitController: WhisperKitLiveController
  #if !APP_STORE
  private var sherpaOnnxController: SherpaOnnxLiveController
  #endif
  private var unsupportedLocalLiveController: UnsupportedLocalLiveTranscriber
  private var currentLanguage: String?
  private var currentModel: String?
  private var invalidateBeforeNextStart: Bool = false
  private var lastStopDate: Date?
  private var willSleepObserver: NSObjectProtocol?
  private var didWakeObserver: NSObjectProtocol?

  // swiftlint:disable:next function_body_length
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
    nativeController = NativeOSXLiveTranscriber(
      permissionsManager: permissionsManager,
      appSettings: appSettings,
      audioDeviceManager: audioDeviceManager
    )
    speechAnalyzerController = AppleSpeechAnalyzerLiveController(
      permissionsManager: permissionsManager,
      appSettings: appSettings,
      audioDeviceManager: audioDeviceManager
    )
    deepgramController = DeepgramLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    modulateController = ModulateLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    assemblyAIController = AssemblyAILiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    elevenlabsController = ElevenLabsLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    sonioxController = SonioxLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    speechmaticsController = SpeechmaticsLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    cartesiaController = CartesiaLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    gladiaController = GladiaLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    openAIRealtimeController = OpenAIRealtimeLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    sharedClientController = SharedClientLiveController(
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    fluidAudioController = FluidAudioParakeetLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      modelManager: FluidAudioModelManager.shared
    )
    whisperKitController = WhisperKitLiveController(
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      modelManager: LocalModelManager.shared
    )
    #if !APP_STORE
    sherpaOnnxController = SherpaOnnxLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      runtimeManager: SherpaOnnxRuntimeManager.shared
    )
    #endif
    unsupportedLocalLiveController = UnsupportedLocalLiveTranscriber()
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
      return speechAnalyzerController
    }
    if let route = controllerRoutes.first(where: { model.hasPrefix($0.prefix) }) {
      return route.controller
    }
    // SwitchingLiveTranscriber only routes live transcription models, and
    // OpenAI's only live transcription transport is the Realtime WebSocket
    // API. So any openai/* live model is handled by openAIRealtimeController.
    if model.hasPrefix("openai/") { return openAIRealtimeController }
    if FluidAudioParakeetModel.matches(model) { return fluidAudioController }
    if WhisperKitStreamingModel.matches(model) { return whisperKitController }
    #if !APP_STORE
    if model.hasPrefix("local/streaming/") { return sherpaOnnxController }
    #else
    if model.hasPrefix("local/streaming/") { return unsupportedLocalLiveController }
    #endif
    if ModelRouting.family(for: model).isDownloadedLocal { return unsupportedLocalLiveController }
    return nativeController
  }

  private var controllerRoutes: [(prefix: String, controller: any LiveTranscriptionController)] {
    [
      ("assemblyai/", assemblyAIController),
      ("deepgram/", deepgramController),
      ("modulate/", modulateController),
      ("elevenlabs/", elevenlabsController),
      ("soniox/", sonioxController),
      ("speechmatics/", speechmaticsController),
      ("cartesia/", cartesiaController),
      ("gladia/", gladiaController),
      ("xai/", sharedClientController)
    ]
  }

  private func applyDelegateAndConfiguration() {
    var controllers: [any LiveTranscriptionController] = [
      nativeController,
      speechAnalyzerController,
      deepgramController,
      modulateController,
      assemblyAIController,
      elevenlabsController,
      sonioxController,
      speechmaticsController,
      cartesiaController,
      gladiaController,
      openAIRealtimeController,
      sharedClientController,
      unsupportedLocalLiveController
    ]
    controllers.insert(whisperKitController, at: controllers.count - 1)
    controllers.insert(fluidAudioController, at: controllers.count - 1)
    #if !APP_STORE
    controllers.insert(sherpaOnnxController, at: controllers.count - 1)
    #endif
    let model = currentModel ?? appSettings.liveTranscriptionModel
    for controller in controllers {
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

  // swiftlint:disable:next function_body_length
  private func resetControllers() {
    activeController = nil
    nativeController = NativeOSXLiveTranscriber(
      permissionsManager: permissionsManager,
      appSettings: appSettings,
      audioDeviceManager: audioDeviceManager
    )
    speechAnalyzerController = AppleSpeechAnalyzerLiveController(
      permissionsManager: permissionsManager,
      appSettings: appSettings,
      audioDeviceManager: audioDeviceManager
    )
    deepgramController = DeepgramLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    modulateController = ModulateLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    assemblyAIController = AssemblyAILiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    elevenlabsController = ElevenLabsLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    sonioxController = SonioxLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    speechmaticsController = SpeechmaticsLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    cartesiaController = CartesiaLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    gladiaController = GladiaLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    openAIRealtimeController = OpenAIRealtimeLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    sharedClientController = SharedClientLiveController(
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    fluidAudioController = FluidAudioParakeetLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      modelManager: FluidAudioModelManager.shared
    )
    whisperKitController = WhisperKitLiveController(
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      modelManager: LocalModelManager.shared
    )
    #if !APP_STORE
    sherpaOnnxController = SherpaOnnxLiveController(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      runtimeManager: SherpaOnnxRuntimeManager.shared
    )
    #endif
    unsupportedLocalLiveController = UnsupportedLocalLiveTranscriber()
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
}
