import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = SpeakLogger.logger(category: "SwitchingLiveTranscriber")

// MARK: - Switching Live Transcriber

// Routes to appropriate live transcription controller based on selected model.
final class SwitchingLiveTranscriber: LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate? {
    didSet {
      applyDelegateAndConfiguration()
    }
  }

  var isRunning: Bool {
    activeController?.isRunning ?? false
  }

  var stopCompletionTimeout: TimeInterval { activeController?.stopCompletionTimeout ?? 10 }

  /// Notified whenever ownership of the live session moves to another
  /// controller (or is released on stop), so transcript display state can be
  /// scoped to the controller that is actually recording (issue #643).
  var sessionSourceDidChange: (((any LiveTranscriptionController)?) -> Void)?

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private let controllerOverride: ((String) -> any LiveTranscriptionController)?
  private var activeRun: ActiveRun? {
    didSet {
      sessionSourceDidChange?(activeController)
    }
  }
  private var pendingStop: PendingStop?
  private var activeController: (any LiveTranscriptionController)? { activeRun?.controller }
  private var controllers: LiveControllerSet
  private let freshness: LiveControllerCacheFreshness
  private var currentLanguage: String?
  private var currentModel: String?

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
    freshness = LiveControllerCacheFreshness(nowProvider: nowProvider)
    self.controllerOverride = controllerOverride
    controllers = LiveControllerSet(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    applyDelegateAndConfiguration()
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
    analyzerFallbackAllowed: Bool = true,
    primedInput: PrimedLiveInput? = nil
  ) async throws {
    if let activeRun {
      await stop(activeRun)
    }
    try Task.checkCancellation()

    let model = currentModel ?? appSettings.liveTranscriptionModel
    logger.info("Starting with model: \(model)")
    if freshness.shouldResetBeforeStart {
      logger.info("Resetting cached live controllers before start")
      resetControllers()
    }

    let controller = controller(for: model)
    controller.delegate = delegate
    controller.configure(language: currentLanguage, model: model)
    let run = activate(controller, preRollBuffers: preRollBuffers, primedInput: primedInput)
    do {
      try await awaitStartup(run)
      freshness.recordSuccessfulStart()
    } catch {
      if error is CancellationError || Task.isCancelled || run.startTask.isCancelled {
        await stop(run)
        throw CancellationError()
      }
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
          try await awaitStartup(fallbackRun)
          freshness.recordSuccessfulStart()
          return
        } catch {
          if error is CancellationError || Task.isCancelled || fallbackRun.startTask.isCancelled {
            await stop(fallbackRun)
            throw CancellationError()
          }
          release(fallbackRun)
          freshness.markStale()
          throw error
        }
      }
      release(run)
      freshness.markStale()
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
    // Cancel synchronously, before the teardown task gets its next actor turn.
    activeRun.startTask.cancel()
    Task { @MainActor [weak self] in
      await self?.stop(activeRun)
    }
  }

  /// Whether `model`'s controller captures through `LiveInputEngines.shared`,
  /// i.e. whether preparing a live input engine before capture is worthwhile.
  func usesLiveInputEngine(for model: String) -> Bool {
    controller(for: model) is LiveInputEngineConsumer
  }

  func controller(for model: String) -> any LiveTranscriptionController {
    if let controllerOverride { return controllerOverride(model) }
    return controllers.controller(for: model)
  }

  private func applyDelegateAndConfiguration() {
    let model = currentModel ?? appSettings.liveTranscriptionModel
    for controller in controllers.all {
      controller.delegate = delegate
      controller.configure(language: currentLanguage, model: model)
    }
  }

  private func resetControllers() {
    activeRun = nil
    controllers = LiveControllerSet(
      appSettings: appSettings,
      permissionsManager: permissionsManager,
      audioDeviceManager: audioDeviceManager,
      secureStorage: secureStorage
    )
    freshness.recordReset()
    applyDelegateAndConfiguration()
  }

  @discardableResult
  private func activate(
    _ controller: any LiveTranscriptionController,
    preRollBuffers: [AVAudioPCMBuffer] = [],
    primedInput: PrimedLiveInput? = nil
  ) -> ActiveRun {
    let startTask = Task { @MainActor in
      try Task.checkCancellation()
      if let analyzer = controller as? AppleSpeechAnalyzerLiveController {
        try await analyzer.start(preRollBuffers: preRollBuffers, primedInput: primedInput)
      } else {
        try await controller.start()
      }
    }
    let run = ActiveRun(controller: controller, startTask: startTask)
    activeRun = run
    return run
  }

  /// Propagate caller cancellation to the provider task. Even a provider that
  /// ignores cancellation must finish starting before its run can be released.
  private func awaitStartup(_ run: ActiveRun) async throws {
    let startTask = run.startTask
    let runID = run.id
    try await withTaskCancellationHandler {
      try await startTask.value
      try Task.checkCancellation()
      guard !startTask.isCancelled else { throw CancellationError() }
    } onCancel: {
      startTask.cancel()
      // Some providers only resolve startup when stop() is called. Cancelling
      // their task alone would leave this await suspended forever. Capture the
      // run ID so delayed cancellation cannot stop a replacement recording.
      Task { @MainActor [weak self] in
        guard let self, let activeRun = self.activeRun, activeRun.id == runID else { return }
        await self.stop(activeRun)
      }
    }
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
      run.startTask.cancel()
      task = Task { @MainActor in
        // Some local controllers need stop() to resolve their startup wait.
        // Others ignore stop while isRunning is false, then acquire capture
        // late. Retain this run through both phases and sweep up late capture.
        await run.controller.stop()
        _ = await run.startTask.result
        if run.controller.isRunning {
          await run.controller.stop()
        }
      }
      pendingStop = PendingStop(run: run, task: task)
    }

    await task.value
    if pendingStop?.run.id == run.id {
      pendingStop = nil
    }
    guard activeRun?.id == run.id else { return }
    activeRun = nil
    freshness.recordStop()
  }

  private struct ActiveRun {
    let id = UUID()
    let controller: any LiveTranscriptionController
    let startTask: Task<Void, Error>
  }

  private struct PendingStop {
    let run: ActiveRun
    let task: Task<Void, Never>
  }

  /// Whether the controller cache has been marked stale and will reset on next start.
  var isCacheStale: Bool { freshness.isStale }

  @MainActor
  func markControllersStale() {
    freshness.markStale()
  }
}
