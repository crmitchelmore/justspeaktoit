// swiftlint:disable file_length
import SpeakCore
import AppKit
@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = SpeakLogger.logger(category: "SwitchingLiveTranscriber")

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

  /// Notified whenever ownership of the live session moves to another
  /// controller (or is released on stop), so transcript display state can be
  /// scoped to the controller that is actually recording (issue #643).
  var sessionSourceDidChange: (((any LiveTranscriptionController)?) -> Void)?

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private let nowProvider: () -> Date
  private let controllerOverride: ((String) -> any LiveTranscriptionController)?
  private var activeRun: ActiveRun? {
    didSet {
      sessionSourceDidChange?(activeController)
    }
  }
  private var pendingStop: PendingStop?
  private var activeController: (any LiveTranscriptionController)? { activeRun?.controller }
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
    nowProvider: @escaping () -> Date = Date.init,
    controllerOverride: ((String) -> any LiveTranscriptionController)? = nil
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.secureStorage = secureStorage
    self.nowProvider = nowProvider
    self.controllerOverride = controllerOverride
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
    logger.info("Configured with model: \(model)")
    applyDelegateAndConfiguration()
  }

  func start() async throws {
    try await start(preRollBuffers: [], analyzerFallbackAllowed: true)
  }

  func start(
    preRollBuffers: [AVAudioPCMBuffer],
    analyzerFallbackAllowed: Bool = true
  ) async throws {
    if let activeRun {
      await stop(activeRun)
    }

    let model = currentModel ?? appSettings.liveTranscriptionModel
    logger.info("Starting with model: \(model)")
    if shouldResetControllersBeforeStart(at: nowProvider()) {
      logger.info("Resetting cached live controllers before start")
      resetControllers()
    }

    let controller = controller(for: model)
    controller.delegate = delegate
    controller.configure(language: currentLanguage, model: model)
    let run = activate(controller)
    do {
      if let analyzer = controller as? AppleSpeechAnalyzerLiveController {
        try await analyzer.start(preRollBuffers: preRollBuffers)
      } else {
        try await controller.start()
      }
      invalidateBeforeNextStart = false
    } catch {
      if AppleLocalModels.isSpeechAnalyzerModel(model), analyzerFallbackAllowed {
        logger.warning(
          "SpeechAnalyzer failed (\(error.localizedDescription, privacy: .public)); using legacy Apple Speech")
        let nativeController = controllers.native
        nativeController.configure(
          language: currentLanguage,
          model: AppleLocalModels.legacySpeechModelID
        )
        let fallbackRun = activate(nativeController)
        do {
          try await nativeController.start()
          invalidateBeforeNextStart = false
          return
        } catch {
          release(fallbackRun)
          invalidateBeforeNextStart = true
          throw error
        }
      }
      release(run)
      invalidateBeforeNextStart = true
      throw error
    }
  }

  func stop() async {
    logger.info("Stopping")
    guard let activeRun else { return }
    await stop(activeRun)
  }

  /// Captures the current run before asynchronous teardown is scheduled. This
  /// prevents a delayed cancellation task from targeting a replacement run.
  func scheduleStop() {
    guard let activeRun else { return }
    Task { @MainActor [weak self] in
      await self?.stop(activeRun)
    }
  }

  func controller(for model: String) -> any LiveTranscriptionController {
    if let controllerOverride { return controllerOverride(model) }
    if AppleLocalModels.isSpeechAnalyzerModel(model) {
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
    activeRun = nil
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

  @discardableResult
  private func activate(_ controller: any LiveTranscriptionController) -> ActiveRun {
    let run = ActiveRun(controller: controller)
    activeRun = run
    return run
  }

  private func release(_ run: ActiveRun) {
    guard activeRun?.id == run.id else { return }
    activeRun = nil
  }

  /// Serialises teardown with a replacement start. The run ID matters because
  /// cached controllers can represent both recordings with the same object.
  private func stop(_ run: ActiveRun) async {
    guard activeRun?.id == run.id || pendingStop?.run.id == run.id else { return }
    let task: Task<Void, Never>
    if let pendingStop, pendingStop.run.id == run.id {
      task = pendingStop.task
    } else {
      task = Task { @MainActor in
        await run.controller.stop()
      }
      pendingStop = PendingStop(run: run, task: task)
    }

    await task.value
    if pendingStop?.run.id == run.id {
      pendingStop = nil
    }
    guard activeRun?.id == run.id else { return }
    activeRun = nil
    lastStopDate = nowProvider()
  }

  private struct ActiveRun {
    let id = UUID()
    let controller: any LiveTranscriptionController
  }

  private struct PendingStop {
    let run: ActiveRun
    let task: Task<Void, Never>
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
        secureStorage: secureStorage,
        appSettings: appSettings
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
