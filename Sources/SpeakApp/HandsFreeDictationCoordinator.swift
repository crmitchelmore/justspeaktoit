import SpeakCore
@preconcurrency import AVFoundation
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
    let startCapture: () async -> Void
    let stopCapture: () async -> Void
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
  private var cooldownTask: Task<Void, Never>?
  /// Serialises arm/disarm so a double hotkey press cannot leave a detector
  /// running with no state machine tracking it.
  private var isTransitioning = false

  init(
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    callbacks: Callbacks
  ) {
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.callbacks = callbacks
  }

  var isArmed: Bool { machine.isArmed }
  var isCapturing: Bool { machine.isCapturing }
  var state: HandsFreeDictationMachine.State { machine.state }

  /// Arms when disarmed, disarms otherwise. This is what the hotkey calls when
  /// hands-free dictation is on.
  func toggle() async {
    guard !isTransitioning else { return }
    isTransitioning = true
    defer { isTransitioning = false }
    await apply(machine.handle(.userToggled))
  }

  /// Tears everything down, e.g. when the setting is switched off or the app
  /// quits. Safe to call when already disarmed.
  func disarm() async {
    guard machine.isArmed else { return }
    await toggle()
  }

  /// The capture the coordinator started has delivered its transcript, so the
  /// session can cool down and re-arm.
  func captureFinished() async {
    await apply(machine.handle(.captureFinished))
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
        await startDetector()
      case .stopDetector:
        await stopDetector()
      case .startCapture:
        await callbacks.startCapture()
      case .stopCapture:
        await callbacks.stopCapture()
      case .startCooldown:
        startCooldown()
      case .reportFailure(let failure):
        logger.error("Hands-free dictation failed: \(failure.rawValue, privacy: .public)")
        callbacks.failed(failure.message)
      }
    }
    callbacks.armedStateChanged(machine.state)
  }

  private func startCooldown() {
    cooldownTask?.cancel()
    cooldownTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(HandsFreeDictationPolicy.cooldownSeconds))
      guard !Task.isCancelled, let self else { return }
      self.tracker.reset()
      await self.apply(self.machine.handle(.cooldownElapsed))
    }
  }

  // MARK: - Detector session

  private func startDetector() async {
    guard #available(macOS 26.0, *) else {
      await fail(AppleLocalModelError.speechDetectorUnavailable)
      return
    }
    guard await permissionsManager.ensureGranted(.microphone).isGranted else {
      await fail(AppleLocalModelError.compatibleAudioFormatUnavailable)
      return
    }

    tracker.reset()
    let inputSession = await audioDeviceManager.beginUsingPreferredInput()
    do {
      try await startDetectorSession()
      self.inputSession = inputSession
    } catch {
      await audioDeviceManager.endUsingPreferredInput(session: inputSession)
      await fail(error)
    }
  }

  @available(macOS 26.0, *)
  private func startDetectorSession() async throws {
    let session = try await AppleSpeechDetectorSession { [weak self] update in
      Task { @MainActor [weak self] in
        await self?.handleActivity(update)
      }
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
      inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
        guard let converted = converter.convert(buffer) else { return }
        session.send(converted)
      }
      try await startAudioEngineAfterInputDeviceSettles(engine)
      audioEngine = engine
      detectorSession = session
    } catch {
      engine.stop()
      inputNode.removeTap(onBus: 0)
      await session.cancel()
      throw error
    }
  }

  private func handleActivity(_ update: AppleSpeechActivityUpdate) async {
    guard machine.isArmed else { return }
    guard let event = tracker.observe(
      speechDetected: update.speechDetected,
      atSeconds: update.seconds
    ) else { return }
    await apply(machine.handle(event))
  }

  private func stopDetector() async {
    cooldownTask?.cancel()
    cooldownTask = nil
    tracker.reset()

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
    await apply(machine.handle(sessionError: error))
  }
}
