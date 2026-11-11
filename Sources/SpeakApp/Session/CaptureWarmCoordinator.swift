import AppKit
import Combine
import Foundation
import Network
import SpeakCore

/// Keeps the capture start path warm while the app is idle (issue #663).
///
/// Three independent warm-ups, all driven from the same lifecycle:
///
/// 1. **Audio input.** A recorder is created and prepared while idle so the
///    hotkey path only has to call `record()`. The microphone is never opened
///    by pre-warming — see `CaptureWarmStage.prepare(for:captureIdle:)` for the
///    privacy boundary — and the staged recorder is discarded and rebuilt
///    whenever the audio route, device selection, recordings directory or
///    microphone permission changes.
/// 2. **Streaming provider endpoint** (`StreamingEndpointWarmUp`). A
///    credential-free HTTPS probe for live clients that use `URLSession.shared`.
/// 3. **On-device SpeechAnalyzer model** (`SpeechAnalyzerWarmUp`).
///
/// Warm-up is suspended for the duration of a session and resumed when the app
/// returns to idle, so it never competes with a live capture.
@MainActor
final class CaptureWarmCoordinator {
  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioInputDeviceManager: AudioInputDeviceManager
  private let audioFileManager: AudioFileManager
  private let systemEvents: CaptureWarmSystemEvents
  private let warmAudio: @MainActor (CaptureWarmContext, Bool) async -> Void
  private let invalidateAudio: @MainActor () async -> Void

  private let endpoint: StreamingEndpointWarmUp
  private var isSessionActive = false
  private var isStarted = false
  private var isInvalidated = false
  private var cancellables: Set<AnyCancellable> = []
  private var audioWarmTask: Task<Void, Never>?
  private var audioWarmGeneration = 0
  private var knownRecordingsDirectory: URL?
  private let speechAnalyzer: SpeechAnalyzerWarmUp

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioInputDeviceManager: AudioInputDeviceManager,
    audioFileManager: AudioFileManager,
    endpointWarmer: StreamingEndpointWarming? = nil,
    networkMonitor: CaptureWarmNetworkMonitoring? = nil,
    scheduler: CaptureWarmScheduling? = nil,
    workspaceNotificationCenter: NotificationCenter? = nil,
    notificationCenter: NotificationCenter? = nil,
    now: (@MainActor () -> Date)? = nil,
    warmAudio: (@MainActor (CaptureWarmContext, Bool) async -> Void)? = nil,
    invalidateAudio: (@MainActor () async -> Void)? = nil,
    warmSpeechAnalyzer: (@Sendable (String, String) async -> Bool)? = nil
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioInputDeviceManager = audioInputDeviceManager
    self.audioFileManager = audioFileManager
    self.systemEvents = CaptureWarmSystemEvents(
      workspaceNotificationCenter: workspaceNotificationCenter ?? NSWorkspace.shared.notificationCenter,
      notificationCenter: notificationCenter ?? .default,
      networkMonitor: networkMonitor ?? SystemCaptureWarmNetworkMonitor()
    )
    if let warmAudio {
      self.warmAudio = warmAudio
    } else {
      self.warmAudio = { context, enabled in
        await audioFileManager.reconcileWarmRecorder(for: context, enabled: enabled)
      }
    }
    self.invalidateAudio = invalidateAudio ?? {
      await audioFileManager.invalidateWarmRecorder()
    }
    self.endpoint = StreamingEndpointWarmUp(
      settings: appSettings,
      warmer: endpointWarmer ?? StreamingEndpointWarmer(),
      scheduler: scheduler ?? SystemCaptureWarmScheduler(),
      now: now ?? Date.init
    )
    self.speechAnalyzer = SpeechAnalyzerWarmUp(warm: warmSpeechAnalyzer ?? SpeechAnalyzerWarmUp.prewarm)
    self.endpoint.onWake = { [weak self] in self?.warmUp() }
  }

  func start() {
    guard !self.isStarted else { return }
    self.isStarted = true
    self.observeEnvironmentChanges()
    self.observeSystemEvents()

    let eventSink = CaptureWarmLifecycleSink(coordinator: self)
    let manager = self.audioFileManager
    Task { [weak self, eventSink] in
      await manager.setRecordingLifecycleHandler { event in
        eventSink.handle(event)
      }
      await MainActor.run {
        self?.warmUp()
      }
    }
  }

  // MARK: - Triggers

  /// Brings both warm-ups in line with the current environment. Safe to call
  /// from any trigger; it no-ops when nothing has changed.
  func warmUp() {
    guard self.isStarted, !self.isInvalidated, !self.isSessionActive else { return }
    self.reconcileSpeechAnalyzerWarmUp()
    self.permissionsManager.refresh(.microphone)
    guard self.permissionsManager.status(for: .microphone).isGranted else {
      self.reconcileAudioWarmUp()
      self.endpoint.invalidate()
      return
    }
    self.reconcileAudioWarmUp()
    self.endpoint.reconcile()
  }

  /// Called when a session starts. Returns the context to hand to
  /// `AudioFileManager.startRecording(warmContext:)`. The recorder actor owns
  /// the authoritative warm state and reports whether it actually claimed it.
  func claimWarmContext() -> CaptureWarmContext? {
    self.sessionWillBegin()
    let context = self.currentContext()
    return self.appSettings.audioPreWarmingEnabled && context.isWarmable ? context : nil
  }

  func sessionWillBegin() {
    self.isSessionActive = true
    self.audioWarmTask?.cancel()
    self.audioWarmTask = nil
    self.speechAnalyzer.cancel()
    self.endpoint.invalidate()
  }

  /// Called when the app returns to idle after a session.
  func sessionDidEnd() {
    guard !self.isInvalidated else { return }
    self.isSessionActive = false
    self.warmUp()
  }

  /// Drops all warm state and waits for the staged file to be removed.
  func invalidate() async {
    guard !self.isInvalidated else { return }
    self.isInvalidated = true
    let endpointProbeTask = self.endpoint.probeTask
    self.endpoint.invalidate()
    self.audioWarmTask?.cancel()
    let speechAnalyzerWarmTask = self.speechAnalyzer.task
    self.speechAnalyzer.cancel()
    self.systemEvents.stop()
    self.cancellables.removeAll()
    await self.audioWarmTask?.value
    await endpointProbeTask?.value
    await speechAnalyzerWarmTask?.value
    await self.audioFileManager.setRecordingLifecycleHandler(nil)
    await self.invalidateAudio()
  }

  // MARK: - Audio input

  /// Hands the current environment to the recorder actor.
  ///
  /// Reconciles run one after another, newest wins. Cancelling the previous
  /// task is not enough on its own: a task that has already passed its
  /// cancellation check can still reach the actor after a newer one, which
  /// would stage a recorder for an environment that no longer holds. Each task
  /// therefore waits for its predecessor and re-checks the generation it was
  /// created for before it enqueues anything.
  private func reconcileAudioWarmUp() {
    let context = self.currentContext()
    let enabled = self.appSettings.audioPreWarmingEnabled
    let previous = self.audioWarmTask
    previous?.cancel()
    self.audioWarmGeneration &+= 1
    let generation = self.audioWarmGeneration
    self.audioWarmTask = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self, self.audioWarmGeneration == generation else { return }
      await self.warmAudio(context, enabled)
    }
  }

  /// The environment the next session would start in.
  ///
  /// `requiresDefaultDeviceSwitch` mirrors `AudioInputDeviceManager`: a
  /// preferred device that is not already the system default is only activated
  /// at session start, so a recorder staged beforehand could capture from the
  /// wrong microphone. Those sessions deliberately take the cold path.
  private func currentContext() -> CaptureWarmContext {
    let preferredUID = self.audioInputDeviceManager.selectedDeviceUID
    let activeUID = self.audioInputDeviceManager.activeDeviceUID
    let requiresSwitch = preferredUID != nil && preferredUID != activeUID
    return CaptureWarmContext(
      inputDeviceUID: activeUID,
      recordingsDirectoryPath: self.appSettings.recordingsDirectory.path,
      encoderProfileID: AudioFileManager.encoderProfileID,
      requiresDefaultDeviceSwitch: requiresSwitch,
      microphonePermissionGranted: self.permissionsManager.status(for: .microphone).isGranted
    )
  }

  // MARK: - On-device SpeechAnalyzer model

  private func reconcileSpeechAnalyzerWarmUp() {
    let model = self.appSettings.liveTranscriptionModel
    guard self.appSettings.transcriptionMode == .liveNative,
      AppleLocalModels.isSpeechAnalyzerModel(model),
      self.permissionsManager.status(for: .speechRecognition).isGranted
    else {
      self.speechAnalyzer.forget()
      return
    }
    let locale = self.appSettings.preferredModelLanguage ?? self.appSettings.resolvedPreferredLocaleIdentifier
    self.speechAnalyzer.warm(model: model, locale: locale)
  }

  // MARK: - Observation

  /// Re-warms on everything that can invalidate a staged recorder or a warm
  /// endpoint. The audio device publishers are fed by the CoreAudio hardware
  /// listeners `AudioInputDeviceManager` already installs, so route changes
  /// (device added/removed, default input changed) land here for free.
  private func observeEnvironmentChanges() {
    self.rewarm(on: self.audioInputDeviceManager.$activeDeviceUID)
    self.rewarm(on: self.audioInputDeviceManager.$selectedDeviceUID)
    self.rewarm(on: self.appSettings.$recordingsDirectory)
    self.sweepStagingOnRecordingsDirectoryChange()
    self.rewarm(on: self.appSettings.$audioPreWarmingEnabled)
    self.rewarm(on: self.appSettings.$connectionPreWarmingEnabled)
    self.rewarm(on: self.permissionsManager.$statuses)

    self.invalidateEndpoint(on: self.appSettings.$transcriptionMode)
    self.invalidateEndpoint(on: self.appSettings.$liveTranscriptionModel)
    self.invalidateEndpoint(on: self.appSettings.$preferredLocaleIdentifier)
    self.invalidateEndpoint(on: self.appSettings.$assemblyAIKeyterms)
    self.invalidateEndpoint(on: self.appSettings.$trackedAPIKeyIdentifiers)
  }

  /// Sweeps both staging folders when the user moves their recordings.
  ///
  /// The launch sweep only knows the directory in use, so a staged file left
  /// beside the old one by a crashed run would stay there for ever. The first
  /// value only records where the recordings are; a sweep needs a real change.
  private func sweepStagingOnRecordingsDirectoryChange() {
    self.appSettings.$recordingsDirectory
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] directory in
        guard let self else { return }
        defer { self.knownRecordingsDirectory = directory }
        guard let previous = self.knownRecordingsDirectory, previous != directory else { return }
        RecordingFiles.scheduleStagedLeftoverSweep(in: previous)
        RecordingFiles.scheduleStagedLeftoverSweep(in: directory)
      }
      .store(in: &self.cancellables)
  }

  private func rewarm<P: Publisher>(on publisher: P) where P.Output: Equatable, P.Failure == Never {
    publisher
      .removeDuplicates()
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.warmUp() }
      .store(in: &self.cancellables)
  }

  private func invalidateEndpoint<P: Publisher>(on publisher: P)
    where P.Output: Equatable, P.Failure == Never {
    publisher
      .removeDuplicates()
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.endpoint.invalidate()
        self?.warmUp()
      }
      .store(in: &self.cancellables)
  }

  /// Sleep drops the warm endpoint; wake, a credential change or a network
  /// that comes back re-warms (the SpeechAnalyzer model may not survive sleep).
  private func observeSystemEvents() {
    self.systemEvents.start(
      CaptureWarmSystemEvents.Handlers(
        willSleep: { [weak self] in self?.endpoint.invalidate() },
        didWake: { [weak self] in
          self?.speechAnalyzer.forgetWarmedModel()
          self?.endpoint.invalidate()
          self?.warmUp()
        },
        networkChanged: { [weak self] isSatisfied in
          self?.endpoint.invalidate()
          if isSatisfied { self?.warmUp() }
        },
        credentialsChanged: { [weak self] in
          self?.endpoint.invalidate()
          self?.warmUp()
        }
      )
    )
  }

  fileprivate func handleRecordingLifecycle(_ event: AudioRecordingLifecycleEvent) {
    switch event {
    case .auxiliaryStarted:
      // An auxiliary recording owns the microphone exactly as a dictation
      // session does, so it suspends warm-up the same way.
      self.sessionWillBegin()
    case .auxiliaryEnded:
      self.sessionDidEnd()
    }
  }
}

private final class CaptureWarmLifecycleSink: @unchecked Sendable {
  private weak var coordinator: CaptureWarmCoordinator?

  init(coordinator: CaptureWarmCoordinator) {
    self.coordinator = coordinator
  }

  func handle(_ event: AudioRecordingLifecycleEvent) {
    Task { @MainActor [weak self] in
      self?.coordinator?.handleRecordingLifecycle(event)
    }
  }
}
