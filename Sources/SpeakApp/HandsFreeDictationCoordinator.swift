import SpeakCore
@preconcurrency import AVFoundation
import AppKit
import Foundation
import os.log

/// Owns hands-free ("armed") dictation on macOS: the microphone tap feeding
/// Apple's `SpeechDetector`, the cooldown timer, and the pure
/// ``HandsFreeDictationMachine`` that decides what happens next.
///
/// The session owner only sees `toggle()` / `disarm()` / `captureFinished()`
/// and the callbacks it supplied; nothing about Speech, AVFoundation or the
/// OS-version gate leaks out. Below macOS 26 arming always fails with a clear
/// message rather than silently doing nothing.
@MainActor
final class HandsFreeDictationCoordinator {
  /// What the coordinator asks the session owner to do. Kept as closures so the
  /// coordinator never reaches into `MainManager`'s session internals.
  struct Callbacks {
    let startCapture: ([AVAudioPCMBuffer]) async -> HandsFreeCaptureStartOutcome
    let stopCapture: () async -> HandsFreeCaptureEndOutcome
    let cancelCapture: () -> Void
    let silenceDuration: () -> TimeInterval
    let captureIsSupported: () -> Bool
    let armedStateChanged: (HandsFreeDictationMachine.State) -> Void
    let failed: (String) -> Void
  }

  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let callbacks: Callbacks
  private let logger = Logger(subsystem: "com.github.speakapp", category: "HandsFree")

  private var machine = HandsFreeDictationMachine()
  private var tracker = HandsFreeVoiceActivityTracker()
  private var audioEngine: AVAudioEngine?
  private var detectorSession: Any?
  private var inputSession: AudioInputDeviceManager.SessionContext?
  private let preRoll = HandsFreeAudioPreRollBuffer()
  private var armTask: Task<Void, Never>?
  private var finalisationTask: Task<Void, Never>?
  private var armID: UUID?
  private var willSleepObserver: (any NSObjectProtocol)?
  private var screenLockObserver: (any NSObjectProtocol)?
  private var engineConfigurationObserver: (any NSObjectProtocol)?

  init(
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    callbacks: Callbacks
  ) {
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.callbacks = callbacks
    observeSleepAndScreenLock()
  }

  deinit {
    if let willSleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(willSleepObserver)
    }
    if let screenLockObserver {
      DistributedNotificationCenter.default().removeObserver(screenLockObserver)
    }
    if let engineConfigurationObserver {
      NotificationCenter.default.removeObserver(engineConfigurationObserver)
    }
  }

  var isArmed: Bool { machine.isArmed }
  var state: HandsFreeDictationMachine.State { machine.state }

  /// Arms when disarmed, disarms otherwise. This is what the hotkey calls when
  /// hands-free dictation is on.
  func toggle() async {
    if machine.isArmed {
      await disarm()
    } else {
      arm()
    }
  }

  /// Tears everything down, e.g. when the setting is switched off or the app
  /// quits. Safe to call when already disarmed.
  func disarm() async {
    armTask?.cancel()
    finalisationTask?.cancel()
    armTask = nil
    armID = nil
    await apply(machine.handle(.userDisarmed))
  }

  /// The capture the coordinator started has delivered its transcript, so the
  /// session can cool down and re-arm.
  func captureFinished(_ outcome: HandsFreeCaptureEndOutcome) async {
    switch outcome {
    case .completed:
      tracker.reset()
      preRoll.reset()
      await apply(machine.handle(.captureFinished))
    case .failed(let failure):
      await apply(machine.handle(.sessionFailed(failure)))
    }
  }

  /// The capture the coordinator started failed; hands-free disarms with a
  /// message instead of leaving the user talking to a dead session.
  func captureFailed(_ error: Error) async {
    await apply(machine.handle(sessionError: error))
  }

  // MARK: - Effects

  private func apply(_ effects: [HandsFreeDictationMachine.Effect]) async {
    for effect in effects {
      switch effect {
      case .startDetector:
        break
      case .stopDetector:
        await stopDetector()
      case .startCapture:
        let outcome = await callbacks.startCapture(preRoll.takeSnapshot())
        if case .rejected(let failure) = outcome {
          // A refused start captured nothing, so it must not cancel a capture.
          // The usual reason for a refusal is that the user already records by
          // hand, and that recording is not ours to stop.
          await apply(machine.handle(.captureStartRejected(failure)))
        }
      case .stopCapture:
        startFinalisation()
      case .cancelCapture:
        callbacks.cancelCapture()
      case .reportFailure(let failure):
        logger.error("Hands-free dictation failed: \(failure.rawValue, privacy: .public)")
        callbacks.failed(failure.message)
      }
    }
    callbacks.armedStateChanged(machine.state)
  }

  private func arm() {
    let effects = machine.handle(.userArmed)
    callbacks.armedStateChanged(machine.state)
    guard effects.contains(.startDetector) else { return }
    guard callbacks.captureIsSupported() else {
      Task { [weak self] in
        guard let self else { return }
        await self.apply(self.machine.handle(.sessionFailed(.unsupportedConfiguration)))
      }
      return
    }
    let id = UUID()
    armID = id
    armTask?.cancel()
    armTask = Task { [weak self] in
      await self?.startDetector(armID: id)
    }
  }

  private func startFinalisation() {
    finalisationTask?.cancel()
    finalisationTask = Task { [weak self] in
      guard let self else { return }
      let outcome = await self.callbacks.stopCapture()
      guard !Task.isCancelled, self.machine.state == .finalising else { return }
      self.finalisationTask = nil
      await self.captureFinished(outcome)
    }
  }

  // MARK: - Detector session

  private func startDetector(armID: UUID) async {
    guard #available(macOS 26.0, *) else {
      await fail(AppleLocalModelError.speechDetectorUnavailable)
      return
    }
    guard await permissionsManager.ensureGranted(.microphone).isGranted else {
      await fail(AppleLocalModelError.compatibleAudioFormatUnavailable)
      return
    }
    guard armAttemptIsCurrent(armID) else { return }

    tracker.reset()
    let inputSession = await audioDeviceManager.beginUsingPreferredInput()
    guard armAttemptIsCurrent(armID) else {
      await audioDeviceManager.endUsingPreferredInput(session: inputSession)
      return
    }
    do {
      try await startDetectorSession(armID: armID)
      guard armAttemptIsCurrent(armID) else {
        await stopDetector()
        await audioDeviceManager.endUsingPreferredInput(session: inputSession)
        return
      }
      self.inputSession = inputSession
      self.armTask = nil
      await apply(machine.handle(.detectorStarted))
    } catch {
      await audioDeviceManager.endUsingPreferredInput(session: inputSession)
      await fail(error)
    }
  }

  @available(macOS 26.0, *)
  private func startDetectorSession(armID: UUID) async throws {
    let session = try await AppleSpeechDetectorSession(
      onActivity: { [weak self] update in
        Task { @MainActor [weak self] in await self?.handleActivity(update) }
      },
      onFailure: { [weak self] error in
        Task { @MainActor [weak self] in
          guard self?.armID == armID, self?.machine.isArmed == true else { return }
          await self?.fail(error)
        }
      }
    )
    guard armAttemptIsCurrent(armID) else {
      await session.cancel()
      throw CancellationError()
    }

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(inputFormat) else {
      await session.cancel()
      throw AppleLocalModelError.compatibleAudioFormatUnavailable
    }

    do {
      let converter = try AppleSpeechAudioConverter(
        sourceFormat: inputFormat,
        targetFormat: session.audioFormat
      )
      inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [preRoll, session] buffer, _ in
        preRoll.append(buffer)
        guard let converted = converter.convert(buffer) else { return }
        session.send(converted)
      }
      try await startAudioEngineAfterInputDeviceSettles(engine)
      audioEngine = engine
      detectorSession = session
      observeEngineConfigurationChange(engine, armID: armID)
    } catch {
      engine.stop()
      inputNode.removeTap(onBus: 0)
      await session.cancel()
      throw error
    }
  }

  private func handleActivity(_ update: AppleSpeechActivityUpdate) async {
    guard machine.state == .armed || machine.state == .recording else { return }
    guard let event = tracker.observe(
      speechDetected: update.speechDetected,
      atSeconds: update.seconds,
      silenceHoldSeconds: HandsFreeDictationPolicy.silenceHoldSeconds(
        configured: callbacks.silenceDuration()
      )
    ) else { return }
    await apply(machine.handle(event))
  }

  private func stopDetector() async {
    armTask?.cancel()
    armTask = nil
    finalisationTask?.cancel()
    finalisationTask = nil
    armID = nil
    tracker.reset()
    preRoll.reset()
    removeEngineConfigurationObserver()

    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine = nil

    if #available(macOS 26.0, *), let session = detectorSession as? AppleSpeechDetectorSession {
      await session.cancel()
    }
    detectorSession = nil

    if let inputSession {
      self.inputSession = nil
      await audioDeviceManager.endUsingPreferredInput(session: inputSession)
    }
  }

  /// Routes a start-up error back through the machine so the failure disarms
  /// and reports through exactly one path.
  private func fail(_ error: Error) async {
    guard !(error is CancellationError) else { return }
    await apply(machine.handle(sessionError: error))
  }

  private func armAttemptIsCurrent(_ id: UUID) -> Bool {
    armID == id && !Task.isCancelled && machine.state == .arming
  }
}

// MARK: - Sleep, screen lock and audio-device changes

extension HandsFreeDictationCoordinator {
  /// An armed detector holds the microphone open, so it must never outlive the
  /// user's presence at the Mac. Sleep and screen lock both disarm. Wake and
  /// unlock never re-arm: an armed microphone that comes back on its own is
  /// exactly what the lock screen protects the user against.
  fileprivate func observeSleepAndScreenLock() {
    willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.disarmForAbsentUser(reason: "the Mac went to sleep")
      }
    }
    screenLockObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.disarmForAbsentUser(reason: "the screen locked")
      }
    }
  }

  /// Disarms because the user is no longer at the Mac. The user arms again by
  /// hand after wake or unlock.
  fileprivate func disarmForAbsentUser(reason: String) async {
    guard machine.isArmed else { return }
    logger.info("Disarming hands-free dictation because \(reason, privacy: .public)")
    await disarm()
  }

  /// The engine reports a configuration change when its input device changes
  /// or disappears — for example when the armed microphone is unplugged. The
  /// tap is dead from that point, so hands-free disarms with a message rather
  /// than showing "Listening for speech" over a detector that hears nothing.
  fileprivate func observeEngineConfigurationChange(_ engine: AVAudioEngine, armID: UUID) {
    removeEngineConfigurationObserver()
    engineConfigurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.armID == armID, self.machine.isArmed else { return }
        self.logger.error("Hands-free audio engine configuration changed; the input is gone")
        await self.apply(self.machine.handle(.sessionFailed(.audioUnavailable)))
      }
    }
  }

  fileprivate func removeEngineConfigurationObserver() {
    guard let engineConfigurationObserver else { return }
    NotificationCenter.default.removeObserver(engineConfigurationObserver)
    self.engineConfigurationObserver = nil
  }
}
