import AppKit
import Combine
import Foundation
import Network
import SpeakCore

@MainActor
protocol CaptureWarmScheduling: AnyObject {
  func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () -> Void)
  func cancel()
}

@MainActor
private final class SystemCaptureWarmScheduler: CaptureWarmScheduling {
  private var task: Task<Void, Never>?

  func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () -> Void) {
    self.cancel()
    self.task = Task { @MainActor in
      let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      operation()
    }
  }

  func cancel() {
    self.task?.cancel()
    self.task = nil
  }
}

@MainActor
protocol CaptureWarmNetworkMonitoring: AnyObject {
  var statusDidChange: ((NWPath.Status) -> Void)? { get set }
  func start()
  func cancel()
}

@MainActor
private final class SystemCaptureWarmNetworkMonitor: CaptureWarmNetworkMonitoring {
  var statusDidChange: ((NWPath.Status) -> Void)?

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.github.speakapp.capture-warm-network")

  func start() {
    self.monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor [weak self] in
        self?.statusDidChange?(path.status)
      }
    }
    self.monitor.start(queue: self.queue)
  }

  func cancel() {
    self.monitor.cancel()
    self.statusDidChange = nil
  }
}

/// Keeps the capture start path warm while the app is idle (issue #663).
///
/// Two independent warm-ups, both driven from the same lifecycle:
///
/// 1. **Audio input.** A recorder is created and prepared while idle so the
///    hotkey path only has to call `record()`. The microphone is never opened
///    by pre-warming — see `AudioFileManager.prepareWarmRecorder(for:)` for the
///    privacy boundary — and the staged recorder is discarded and rebuilt
///    whenever the audio route, device selection, recordings directory or
///    microphone permission changes.
/// 2. **Streaming provider endpoint.** A credential-free HTTPS probe for live
///    clients that use `URLSession.shared`. This warms resolver state and may
///    seed TLS resumption, but does not claim to pre-connect the WebSocket.
///
/// Warm-up is suspended for the duration of a session and resumed when the app
/// returns to idle, so it never competes with a live capture.
@MainActor
final class CaptureWarmCoordinator {
  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioInputDeviceManager: AudioInputDeviceManager
  private let audioFileManager: AudioFileManager
  private let endpointWarmer: StreamingEndpointWarming
  private let networkMonitor: CaptureWarmNetworkMonitoring
  private let scheduler: CaptureWarmScheduling
  private let workspaceNotificationCenter: NotificationCenter
  private let notificationCenter: NotificationCenter
  private let now: @MainActor () -> Date
  private let warmAudio: @MainActor (CaptureWarmContext, Bool) async -> Void
  private let invalidateAudio: @MainActor () async -> Void

  private var streamTracker = LiveStreamWarmTracker()
  private var isSessionActive = false
  private var isStarted = false
  private var isInvalidated = false
  private var lastNetworkStatus: NWPath.Status?
  private var cancellables: Set<AnyCancellable> = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var observers: [NSObjectProtocol] = []
  private var audioWarmTask: Task<Void, Never>?
  private var endpointProbeTask: Task<Void, Never>?

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
    invalidateAudio: (@MainActor () async -> Void)? = nil
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioInputDeviceManager = audioInputDeviceManager
    self.audioFileManager = audioFileManager
    self.endpointWarmer = endpointWarmer ?? StreamingEndpointWarmer()
    self.networkMonitor = networkMonitor ?? SystemCaptureWarmNetworkMonitor()
    self.scheduler = scheduler ?? SystemCaptureWarmScheduler()
    self.workspaceNotificationCenter = workspaceNotificationCenter ?? NSWorkspace.shared.notificationCenter
    self.notificationCenter = notificationCenter ?? .default
    self.now = now ?? Date.init
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
  }

  func start() {
    guard !self.isStarted else { return }
    self.isStarted = true
    self.observeEnvironmentChanges()
    self.observeSleepAndWake()
    self.observeCredentialChanges()
    self.observeNetworkChanges()

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
    self.permissionsManager.refresh(.microphone)
    guard self.permissionsManager.status(for: .microphone).isGranted else {
      self.reconcileAudioWarmUp()
      self.invalidateEndpointWarmUp()
      return
    }
    self.reconcileAudioWarmUp()
    self.reconcileEndpointWarmUp()
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
    self.scheduler.cancel()
    self.endpointProbeTask?.cancel()
    self.endpointProbeTask = nil
    self.streamTracker.invalidate()
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
    self.scheduler.cancel()
    self.endpointProbeTask?.cancel()
    self.audioWarmTask?.cancel()
    self.networkMonitor.cancel()
    for observer in self.workspaceObservers {
      self.workspaceNotificationCenter.removeObserver(observer)
    }
    self.workspaceObservers.removeAll()
    for observer in self.observers {
      self.notificationCenter.removeObserver(observer)
    }
    self.observers.removeAll()
    self.cancellables.removeAll()
    self.streamTracker.invalidate()
    await self.audioWarmTask?.value
    await self.endpointProbeTask?.value
    await self.audioFileManager.setRecordingLifecycleHandler(nil)
    await self.invalidateAudio()
  }

  // MARK: - Audio input

  private func reconcileAudioWarmUp() {
    let context = self.currentContext()
    let enabled = self.appSettings.audioPreWarmingEnabled
    self.audioWarmTask?.cancel()
    self.audioWarmTask = Task { [weak self] in
      guard !Task.isCancelled, let self else { return }
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

  // MARK: - Streaming endpoint

  private func reconcileEndpointWarmUp() {
    let provider = self.currentStreamingProvider()
    let now = self.now()
    guard
      let host = self.streamTracker.hostNeedingWarmUp(
        for: provider,
        now: now,
        enabled: self.appSettings.connectionPreWarmingEnabled
      )
    else {
      self.scheduleEndpointRefresh(for: provider, now: now)
      return
    }

    let warmer = self.endpointWarmer
    self.endpointProbeTask?.cancel()
    self.endpointProbeTask = Task { [weak self] in
      let succeeded = await warmer.warmUp(host: host)
      guard let self, !Task.isCancelled else { return }
      if succeeded {
        let completedAt = self.now()
        if self.streamTracker.markWarmed(host: host, at: completedAt) {
          self.scheduleEndpointRefresh(for: self.currentStreamingProvider(), now: completedAt)
        }
      } else {
        self.streamTracker.markFailed(host: host)
        self.scheduleEndpointRetry()
      }
    }
  }

  private func scheduleEndpointRefresh(
    for provider: LiveTranscriptionProviderID?,
    now: Date
  ) {
    guard let deadline = self.streamTracker.refreshDeadline(
      for: provider,
      enabled: self.appSettings.connectionPreWarmingEnabled
    ) else {
      self.scheduler.cancel()
      return
    }
    self.scheduleEndpointWake(after: max(0, deadline.timeIntervalSince(now)))
  }

  private func scheduleEndpointRetry() {
    self.scheduleEndpointWake(after: 15)
  }

  private func scheduleEndpointWake(after delay: TimeInterval) {
    self.scheduler.schedule(after: delay) { [weak self] in
      self?.warmUp()
    }
  }

  private func invalidateEndpointWarmUp() {
    self.scheduler.cancel()
    self.endpointProbeTask?.cancel()
    self.endpointProbeTask = nil
    self.streamTracker.invalidate()
  }

  /// The streaming provider a session would use right now, or `nil` when the
  /// current mode does not stream to a cloud provider.
  private func currentStreamingProvider() -> LiveTranscriptionProviderID? {
    guard self.appSettings.transcriptionMode == .liveNative else { return nil }
    let availability = ModelCredentialResolver.availability(
      for: self.appSettings.liveTranscriptionModel,
      purpose: .liveTranscription,
      storedAPIKeyIdentifiers: self.appSettings.trackedAPIKeyIdentifiers
    )
    if case .missing = availability { return nil }
    return LiveTranscriptionRouting.route(for: self.appSettings.liveTranscriptionModel)?.provider
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
    self.rewarm(on: self.appSettings.$audioPreWarmingEnabled)
    self.rewarm(on: self.appSettings.$connectionPreWarmingEnabled)
    self.rewarm(on: self.permissionsManager.$statuses)

    self.invalidateEndpoint(on: self.appSettings.$transcriptionMode)
    self.invalidateEndpoint(on: self.appSettings.$liveTranscriptionModel)
    self.invalidateEndpoint(on: self.appSettings.$preferredLocaleIdentifier)
    self.invalidateEndpoint(on: self.appSettings.$assemblyAIKeyterms)
    self.invalidateEndpoint(on: self.appSettings.$trackedAPIKeyIdentifiers)
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
        self?.invalidateEndpointWarmUp()
        self?.warmUp()
      }
      .store(in: &self.cancellables)
  }

  private func observeSleepAndWake() {
    let willSleep = self.workspaceNotificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.invalidateEndpointWarmUp()
      }
    }
    let didWake = self.workspaceNotificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.invalidateEndpointWarmUp()
        self?.warmUp()
      }
    }
    self.workspaceObservers = [willSleep, didWake]
  }

  private func observeNetworkChanges() {
    self.networkMonitor.statusDidChange = { [weak self] status in
      guard let self else { return }
      guard self.lastNetworkStatus != status else { return }
      self.lastNetworkStatus = status
      self.invalidateEndpointWarmUp()
      if status == .satisfied {
        self.warmUp()
      }
    }
    self.networkMonitor.start()
  }

  private func observeCredentialChanges() {
    let observer = self.notificationCenter.addObserver(
      forName: .secureAppStorageDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.invalidateEndpointWarmUp()
        self?.warmUp()
      }
    }
    self.observers.append(observer)
  }

  fileprivate func handleRecordingLifecycle(_ event: AudioRecordingLifecycleEvent) {
    switch event {
    case .auxiliaryStarted:
      self.isSessionActive = true
      self.scheduler.cancel()
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
