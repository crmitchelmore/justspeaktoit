@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import SpeakCore
import SpeakHotKeys

/// Key-down microphone warm-up for the dictation hotkey (see `PrimedLiveInput`
/// and `HotKeyPressPrimer`), and the standby engine it starts.
///
/// Inert unless `AppSettings.warmMicrophoneOnKeyPress` is on, the microphone
/// is already authorised (a key press never prompts), and the next session
/// would capture through a live engine (`LiveInputEngineConsumer` routes).
@MainActor
final class KeyPressPrimerRuntime {
  /// Pre-roll kept before hand-over. Covers the hold threshold and a double
  /// tap with margin.
  static let preRollDuration: TimeInterval = 1.5
  /// Delay before the standby is rebuilt after a session, so the session's
  /// own engine has stopped and the input route has settled.
  static let refillDelay: TimeInterval = 1

  /// What the primer reads to decide whether a key press may open the
  /// microphone, and where it registers for press edges.
  struct Context {
    let settings: AppSettings
    let hotKeys: HotKeyManager
    let devices: AudioInputDeviceManager
    let permissions: PermissionsManager
    let transcription: TranscriptionManager
    let profiles: DictationProfileStore
    let audioFiles: AudioFileManager
    /// True while no session, start, migration, hands-free arming or other
    /// capture reservation can be using the microphone.
    let sessionIsIdle: () -> Bool
  }

  private let context: Context
  private let logger = SpeakLogger.logger(category: "MainManager")
  private let standby: LiveInputStandby<AVAudioEngine>
  /// A refill waiting out its delay. Cancelled by a key-down.
  private var pendingRefill: Task<Void, Never>?
  /// The newest standby build; builds run one after another.
  private var buildTask: Task<Void, Never>?
  private var pressToken: HotKeyPressListenerToken?
  private var cancellables: Set<AnyCancellable> = []
  private(set) var lastKeyDownUptime: TimeInterval?

  private(set) lazy var primer = HotKeyPressPrimer<PrimedLiveInput>(dependencies: makeDependencies())

  init(context: Context, standby: LiveInputStandby<AVAudioEngine> = LiveInputEngines.standby) {
    self.context = context
    self.standby = standby
  }

  // MARK: - Wiring

  func start() {
    guard pressToken == nil else { return }
    pressToken = context.hotKeys.registerPress { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) }
    }
    context.settings.$warmMicrophoneOnKeyPress
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] enabled in
        guard let self else { return }
        if enabled {
          self.scheduleRefill(after: 0)
        } else {
          self.primer.cancel()
          self.cancelPendingRefill()
          self.standby.clear()
        }
      }
      .store(in: &cancellables)
    context.devices.$activeDeviceUID
      .combineLatest(context.devices.$selectedDeviceUID)
      .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.standby.cancelRefill()
        self?.scheduleRefill(after: Self.refillDelay)
      }
      .store(in: &cancellables)
    context.permissions.$statuses
      .map { $0[.microphone]?.isGranted == true }
      .removeDuplicates()
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] granted in
        guard granted else { return }
        self?.scheduleRefill(after: 0)
      }
      .store(in: &cancellables)
  }

  private func handle(_ event: HotKeyPressEvent) {
    switch event.phase {
    case .pressed:
      lastKeyDownUptime = event.uptime
      primer.pressBegan(at: event.uptime)
      // The hold or second tap that starts a session comes 200-500 ms later;
      // query TCC now so the capture start can reuse the answer (#611).
      context.permissions.refresh(.microphone)
    case .released:
      primer.pressEnded(at: event.uptime)
    case .reset:
      primer.cancel()
    }
  }

  // MARK: - Gestures

  /// Timing for a recognised gesture, measured from the key-down that
  /// started it: the latest press for a hold, the first press for a double tap.
  func triggerTiming(for gesture: HotKeyGesture) -> SessionTriggerTiming {
    let keyDown = gesture == .doubleTap ? primer.sequenceKeyDownUptime : lastKeyDownUptime
    return .recognisedHotKey(keyDownUptime: keyDown)
  }

  /// Claims the press's primed microphone for a session the gesture starts.
  func reserve() -> PrimedLiveInputReservation? {
    primer.reserve()
  }

  /// Closes a claimed capture the session did not adopt. A no-op once the
  /// session took it over.
  func release(_ reservation: PrimedLiveInputReservation?) {
    guard let reservation else { return }
    Task { @MainActor [weak self] in
      guard let capture = await reservation.value, capture.isOpen else { return }
      if let self {
        self.primer.enqueueClose(capture)
      } else {
        _ = await capture.close()
      }
    }
  }

  /// Closes a claimed capture and waits until its engine has stopped. For a
  /// start whose route builds its own input node, which must never happen
  /// beside an open microphone.
  func closeBeforeStart(_ reservation: PrimedLiveInputReservation) async {
    guard let capture = await reservation.value, capture.isOpen else { return }
    primer.enqueueClose(capture)
    await primer.settle()
  }

  /// Foreground capture never waits for a speculative input-node build.
  func sessionWillBegin() {
    cancelPendingRefill()
    standby.cancelRefill()
  }

  /// Called whenever the app returns to idle.
  func sessionDidEnd() {
    scheduleRefill(after: Self.refillDelay)
  }

  // MARK: - Primer dependencies

  private func makeDependencies() -> HotKeyPressPrimer<PrimedLiveInput>.Dependencies {
    let standby = self.standby
    return HotKeyPressPrimer<PrimedLiveInput>.Dependencies(
      isEligible: { [weak self] in self?.pressMayOpenMicrophone() ?? false },
      keepsAliveForDoubleTap: { [weak self] in
        self?.context.settings.hotKeyActivationStyle.allowsDoubleTap ?? false
      },
      doubleTapWindow: { [weak self] in self?.context.settings.doubleTapWindow ?? 0.4 },
      safetyTimeout: { [weak self] in
        guard let settings = self?.context.settings else { return 2.5 }
        return max(2.5, settings.holdThreshold + 2 * settings.doubleTapWindow + 1)
      },
      open: { [weak self] keyDownUptime in
        guard let self else { return nil }
        self.cancelPendingRefill()
        standby.cancelRefill()
        let capture = await PrimedLiveInput.open(
          keyDownUptime: keyDownUptime,
          deviceManager: self.context.devices,
          standby: standby,
          preRollDuration: Self.preRollDuration
        )
        let elapsed = Int(((ProcessInfo.processInfo.systemUptime - keyDownUptime) * 1000).rounded())
        if capture == nil {
          self.logger.warning("Key-down microphone warm-up could not start an input (\(elapsed)ms)")
        } else {
          self.logger.info("Latency: key-down microphone running \(elapsed)ms after key-down")
        }
        return capture
      },
      close: { capture in
        guard let stopped = await capture.close() else { return }
        standby.stock(stopped.engine, inputDeviceID: stopped.inputDeviceID)
      },
      schedule: { delay, action in
        let task = Task { @MainActor in
          try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
          guard !Task.isCancelled else { return }
          action()
        }
        return HotKeyPressPrimerTimer { task.cancel() }
      }
    )
  }

  /// Whether a key-down may open the microphone right now. Never true while
  /// anything else could be using it, and never for a route whose controller
  /// would build its own input node.
  private func pressMayOpenMicrophone() -> Bool {
    guard isIdleForMicrophone() else { return false }
    return context.transcription.liveRouteUsesLiveInputEngine(
      profiles: context.profiles.profiles,
      frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    )
  }

  private func isIdleForMicrophone() -> Bool {
    guard context.settings.warmMicrophoneOnKeyPress else { return false }
    return context.sessionIsIdle()
      && context.audioFiles.requiresPhysicalInput
      && !context.devices.devices.isEmpty
      && context.permissions.status(for: .microphone).isGranted
  }

  // MARK: - Standby

  private func scheduleRefill(after delay: TimeInterval) {
    pendingRefill?.cancel()
    pendingRefill = Task { @MainActor [weak self] in
      if delay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      guard !Task.isCancelled else { return }
      self?.buildStandbyIfIdle()
    }
  }

  /// Builds the standby off the main thread, only while nothing has the
  /// microphone open: an input node built beside an open microphone stalls.
  private func buildStandbyIfIdle() {
    let previous = buildTask
    let standby = self.standby
    buildTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !self.primer.isActive, self.isIdleForMicrophone() else { return }
      let token = standby.beginRefill(
        preferredInputDeviceID: self.context.devices.preferredInputDeviceID
      )
      await Task.detached(priority: .utility) { standby.refill(token) }.value
    }
  }

  private func cancelPendingRefill() {
    pendingRefill?.cancel()
    pendingRefill = nil
  }
}

extension HotKeyManager {
  /// Raw press edges of the hotkey, before any gesture is recognised.
  @discardableResult
  func registerPress(handler: @escaping (HotKeyPressEvent) -> Void) -> HotKeyPressListenerToken {
    engine.registerPress(handler: handler)
  }
}
