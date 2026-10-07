@preconcurrency import AVFoundation
import Combine
import Foundation
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

  private weak var owner: MainManager?
  private let standby: LiveInputStandby<AVAudioEngine>
  /// A refill waiting out its delay. Cancelled by a key-down.
  private var pendingRefill: Task<Void, Never>?
  /// The newest standby build; builds run one after another.
  private var buildTask: Task<Void, Never>?
  private var pressToken: HotKeyPressListenerToken?
  private var cancellables: Set<AnyCancellable> = []
  private(set) var lastKeyDownUptime: TimeInterval?

  private(set) lazy var primer = HotKeyPressPrimer<PrimedLiveInput>(dependencies: makeDependencies())

  init(owner: MainManager, standby: LiveInputStandby<AVAudioEngine> = LiveInputEngines.standby) {
    self.owner = owner
    self.standby = standby
  }

  // MARK: - Wiring

  func start() {
    guard let owner, pressToken == nil else { return }
    pressToken = owner.hotKeyManager.registerPress { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) }
    }
    let settings = owner.appSettings
    settings.$warmMicrophoneOnKeyPress
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
    owner.audioInputDeviceManager.$activeDeviceUID
      .removeDuplicates()
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.scheduleRefill(after: Self.refillDelay) }
      .store(in: &cancellables)
    owner.permissionsManager.$statuses
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

  /// Waits for a standby build in flight. A start must not open the
  /// microphone while an input node is still being built beside it.
  func settleStandby() async {
    await buildTask?.value
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
        self?.owner?.appSettings.hotKeyActivationStyle.allowsDoubleTap ?? false
      },
      doubleTapWindow: { [weak self] in self?.owner?.appSettings.doubleTapWindow ?? 0.4 },
      safetyTimeout: { [weak self] in
        guard let settings = self?.owner?.appSettings else { return 2.5 }
        return max(2.5, settings.holdThreshold + 2 * settings.doubleTapWindow + 1)
      },
      open: { [weak self] keyDownUptime in
        guard let self, let owner = self.owner else { return nil }
        self.cancelPendingRefill()
        await self.settleStandby()
        let capture = await PrimedLiveInput.open(
          keyDownUptime: keyDownUptime,
          deviceManager: owner.audioInputDeviceManager,
          standby: standby,
          preRollDuration: Self.preRollDuration
        )
        let elapsed = Int(((ProcessInfo.processInfo.systemUptime - keyDownUptime) * 1000).rounded())
        if capture == nil {
          owner.logger.warning("Key-down microphone warm-up could not start an input (\(elapsed)ms)")
        } else {
          owner.logger.info("Latency: key-down microphone running \(elapsed)ms after key-down")
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
    guard let owner else { return false }
    return owner.isStreamingTranscriptionMode && owner.transcriptionManager.liveRouteUsesLiveInputEngine
  }

  private func isIdleForMicrophone() -> Bool {
    guard let owner, owner.appSettings.warmMicrophoneOnKeyPress else { return false }
    return owner.activeSession == nil
      && !owner.captureStarting
      && !owner.migrationInProgress
      && !owner.handsFreeArmsHotKey
      && owner.captureOwnership.owner == nil
      && owner.audioFileManager.requiresPhysicalInput
      && !owner.audioInputDeviceManager.devices.isEmpty
      && owner.permissionsManager.status(for: .microphone).isGranted
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
      await Task.detached(priority: .utility) { standby.refill() }.value
    }
  }

  private func cancelPendingRefill() {
    pendingRefill?.cancel()
    pendingRefill = nil
  }
}

extension MainManager {
  /// Trigger timing for a recognised hotkey gesture, plus the key-down
  /// primer's microphone when the gesture is about to start a session.
  func recognisedSessionGesture(_ gesture: HotKeyGesture) -> (SessionTriggerTiming, PrimedLiveInputReservation?) {
    let timing = keyPressPrimer.triggerTiming(for: gesture)
    let style = appSettings.hotKeyActivationStyle
    let startsSession = gesture == .holdStart ? style.allowsHold : style.allowsDoubleTap
    guard startsSession, activeSession == nil, !captureStarting, !handsFreeArmsHotKey else {
      return (timing, nil)
    }
    return (timing, keyPressPrimer.reserve())
  }

  /// Logs key-down → capture and key-down → first primed audio, and keeps
  /// them on the session for diagnosis.
  func recordKeyDownLatency(for session: ActiveSession, primedInput: PrimedLiveInputReservation?) async {
    guard let keyDownMs = session.keyDownToCaptureMilliseconds else { return }
    var summary = "capture \(keyDownMs)ms after key-down"
    if let primed = await primedInput?.value {
      let warmUpMs = Int(((primed.startedUptime - primed.keyDownUptime) * 1000).rounded())
      summary += ", microphone warmed at key-down (running at \(warmUpMs)ms"
      if let signalMs = primed.firstSignalMilliseconds {
        summary += ", first audio at \(signalMs)ms)"
      } else {
        summary += ", no audio before hand-over)"
      }
    }
    logger.info("Latency: \(summary, privacy: .public)")
    session.events.append(HistoryEvent(kind: .recordingStarted, description: "Key-down timeline — \(summary)"))
  }
}

extension HotKeyManager {
  /// Raw press edges of the hotkey, before any gesture is recognised.
  @discardableResult
  func registerPress(handler: @escaping (HotKeyPressEvent) -> Void) -> HotKeyPressListenerToken {
    engine.registerPress(handler: handler)
  }
}
