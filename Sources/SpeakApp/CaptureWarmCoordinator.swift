import AppKit
import Combine
import Foundation
import SpeakCore
import os.log

/// Keeps the capture start path warm while the app is idle (issue #663).
///
/// Two independent warm-ups, both driven from the same triggers:
///
/// 1. **Audio input.** A recorder is created and prepared while idle so the
///    hotkey path only has to call `record()`. The microphone is never opened
///    by pre-warming — see `AudioFileManager.prepareWarmRecorder(for:)` for the
///    privacy boundary — and the staged recorder is discarded and rebuilt
///    whenever the audio route, device selection, recordings directory or
///    microphone permission changes.
/// 2. **Streaming provider endpoint.** A DNS + TLS handshake against the
///    selected provider's host, so the `wss://` upgrade at session start skips
///    resolution and can resume the TLS session. No credential is sent and no
///    provider-side session is created; see ``LiveStreamWarmUp`` for why no
///    provider gets a fully pre-connected socket.
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
  private let logger = Logger(subsystem: "com.github.speakapp", category: "CaptureWarmUp")

  private var machine = CaptureWarmStateMachine()
  private var streamTracker = LiveStreamWarmTracker()
  private var isSessionActive = false
  private var cancellables: Set<AnyCancellable> = []

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioInputDeviceManager: AudioInputDeviceManager,
    audioFileManager: AudioFileManager,
    endpointWarmer: StreamingEndpointWarming = StreamingEndpointWarmer()
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioInputDeviceManager = audioInputDeviceManager
    self.audioFileManager = audioFileManager
    self.endpointWarmer = endpointWarmer
    self.observeEnvironmentChanges()
  }

  // MARK: - Triggers

  /// Brings both warm-ups in line with the current environment. Safe to call
  /// from any trigger; it no-ops when nothing has changed.
  func warmUp() {
    guard !self.isSessionActive else { return }
    self.reconcileAudioWarmUp()
    self.reconcileEndpointWarmUp()
  }

  /// Called when a session starts. Returns the context to hand to
  /// `AudioFileManager.startRecording(warmContext:)` when a staged recorder is
  /// ready for exactly this environment, otherwise `nil` (cold path).
  func claimWarmContext() -> CaptureWarmContext? {
    self.isSessionActive = true
    let context = self.currentContext()
    guard self.machine.claim(for: context) else {
      // Anything staged is for a different environment; drop it rather than
      // leave the file behind.
      self.apply(self.machine.reset())
      return nil
    }
    return context
  }

  /// Called when the app returns to idle after a session.
  func sessionDidEnd() {
    self.isSessionActive = false
    self.warmUp()
  }

  /// Drops all warm state, e.g. at app termination.
  func invalidate() {
    let action = self.machine.reset()
    self.streamTracker.invalidate()
    self.apply(action)
  }

  // MARK: - Audio input

  private func reconcileAudioWarmUp() {
    // Off the hot path, so this is the right place to pay for a permission
    // refresh: `currentContext()` is also called at session start and must stay
    // cheap there.
    self.permissionsManager.refresh(.microphone)
    let context = self.currentContext()
    let action = self.machine.reconcile(
      with: context,
      enabled: self.appSettings.audioPreWarmingEnabled
    )
    self.apply(action)
  }

  private func apply(_ action: CaptureWarmAction) {
    switch action {
    case .none:
      return
    case .discard:
      let manager = self.audioFileManager
      Task { await manager.discardWarmRecorder() }
    case .prepare(let context):
      self.stage(context, discardFirst: false)
    case .discardThenPrepare(let context):
      self.stage(context, discardFirst: true)
    }
  }

  private func stage(_ context: CaptureWarmContext, discardFirst: Bool) {
    let manager = self.audioFileManager
    Task { [weak self] in
      if discardFirst { await manager.discardWarmRecorder() }
      let prepared = await manager.prepareWarmRecorder(for: context)
      guard let self else { return }
      guard prepared else {
        self.machine.markFailed(context)
        return
      }
      // The environment may have moved on while we were staging; if so the
      // machine rejects the result and the recorder must not be kept.
      if !self.machine.markReady(context) {
        await manager.discardWarmRecorder()
      }
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
    guard
      let host = self.streamTracker.hostNeedingWarmUp(
        for: provider,
        now: Date(),
        enabled: self.appSettings.connectionPreWarmingEnabled
      )
    else {
      return
    }

    let warmer = self.endpointWarmer
    Task { [weak self] in
      let succeeded = await warmer.warmUp(host: host)
      guard let self else { return }
      if succeeded {
        self.streamTracker.markWarmed(host: host, at: Date())
      } else {
        self.streamTracker.markFailed(host: host)
      }
    }
  }

  /// The streaming provider a session would use right now, or `nil` when the
  /// current mode does not stream to a cloud provider.
  private func currentStreamingProvider() -> LiveTranscriptionProviderID? {
    guard self.appSettings.transcriptionMode == .liveNative else { return nil }
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

    // A provider change makes the warm host wrong, not merely stale.
    self.appSettings.$liveTranscriptionModel
      .removeDuplicates()
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.streamTracker.invalidate()
        self?.warmUp()
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
}
