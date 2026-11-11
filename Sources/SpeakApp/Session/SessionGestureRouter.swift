import Foundation
import SpeakCore
import SpeakHotKeys

/// What the gesture router needs from the session owner. `MainManager`
/// conforms; tests use a fake so routing rules run without a recorder.
@MainActor
protocol SessionGestureHandling: AnyObject {
  var hotKeyActivationStyle: AppSettings.HotKeyActivationStyle { get }
  /// The gesture that started the active session, nil when none is active.
  var activeSessionGesture: HistoryTrigger.HotKeyGesture? { get }
  /// Whether the hotkey arms hands-free dictation instead of recording.
  var handsFreeArmsHotKey: Bool { get }

  /// Lets hands-free dictation consume the press; true when it did.
  func handleHandsFreeHotKey() async -> Bool
  /// Trigger timing for a recognised gesture and the primed microphone, if any.
  func recognisedSessionGesture(_ gesture: HotKeyGesture) -> (SessionTriggerTiming, PrimedLiveInputReservation?)
  /// Closes a primed microphone that no session will take over.
  func releasePrimedInput(_ primedInput: PrimedLiveInputReservation?)
  func startGestureSession(
    trigger: SessionTriggerSource,
    triggerTiming: SessionTriggerTiming,
    primedInput: PrimedLiveInputReservation?
  ) async
  func endGestureSession(trigger: SessionTriggerSource) async
  func retryPostProcessing()
  func cancelRecordingWithEscape()
}

/// Turns hotkey gestures and app shortcuts into session starts and stops:
/// hold-to-talk, double-tap toggle, single-tap stop and hands-free arming.
/// Owns the listener tokens and the double-tap debounce; the session itself
/// stays with its handler.
@MainActor
final class SessionGestureRouter {
  /// Ignores a double-tap that arrives this soon after the previous one, so
  /// one physical toggle cannot start and immediately end a session.
  nonisolated static let doubleTapDebounce: TimeInterval = 0.25

  private weak var handler: SessionGestureHandling?
  private var hotKeyTokens: [HotKeyListenerToken] = []
  private var shortcutTokens: [ShortcutListenerToken] = []
  private var lastDoubleTapEventUptime: TimeInterval = 0

  init(handler: SessionGestureHandling) {
    self.handler = handler
  }

  /// Registers the session gestures and the ⌘R / Escape shortcuts.
  func register(on hotKeyManager: HotKeyManager) {
    hotKeyTokens.append(
      hotKeyManager.register(gesture: .holdStart) { [weak self] in
        // Stamped here, before the actor hop, so the latency dashboard measures
        // from the key press rather than from where `startSession` gets to run.
        // The key-down primer's microphone is claimed here too, synchronously,
        // so its release timers cannot close it while the session starts.
        let (triggerTiming, primedInput) = MainActor.assumeIsolated {
          self?.handler?.recognisedSessionGesture(.holdStart) ?? (.recognisedHotKey(), nil)
        }
        Task { @MainActor in
          guard let self else { return }
          await self.handleHoldStart(triggerTiming: triggerTiming, primedInput: primedInput)
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .holdEnd) { [weak self] in
        Task { @MainActor in
          await self?.handleHoldEnd()
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .doubleTap) { [weak self] in
        let (triggerTiming, primedInput) = MainActor.assumeIsolated {
          self?.handler?.recognisedSessionGesture(.doubleTap) ?? (.recognisedHotKey(), nil)
        }
        Task { @MainActor in
          guard let self else { return }
          await self.handleDoubleTap(triggerTiming: triggerTiming, primedInput: primedInput)
        }
      }
    )

    hotKeyTokens.append(
      hotKeyManager.register(gesture: .singleTap) { [weak self] in
        Task { @MainActor in
          await self?.handleSingleTap()
        }
      }
    )

    // ⌘R only retries a finished session, so it stays on the app-local monitor and never
    // reaches Safari's reload or Xcode's run.
    shortcutTokens.append(
      hotKeyManager.register(shortcut: .commandR) { [weak self] in
        Task { @MainActor in
          self?.handler?.retryPostProcessing()
        }
      }
    )

    shortcutTokens.append(
      hotKeyManager.register(shortcut: .escape) { [weak self] in
        Task { @MainActor in
          self?.handler?.cancelRecordingWithEscape()
        }
      }
    )
  }

  /// Hands-free replaces press-to-talk with press-to-arm.
  func handleHoldStart(triggerTiming: SessionTriggerTiming, primedInput: PrimedLiveInputReservation?) async {
    guard let handler else { return }
    guard handler.hotKeyActivationStyle.allowsHold, !(await handler.handleHandsFreeHotKey()) else {
      handler.releasePrimedInput(primedInput)
      return
    }
    await handler.startGestureSession(trigger: .hold, triggerTiming: triggerTiming, primedInput: primedInput)
  }

  /// The arming press already consumed the gesture, so releasing the key must
  /// not stop a hands-free capture the detector is still driving.
  func handleHoldEnd() async {
    guard let handler, handler.hotKeyActivationStyle.allowsHold else { return }
    guard !handler.handsFreeArmsHotKey else { return }
    await handler.endGestureSession(trigger: .hold)
  }

  func handleSingleTap() async {
    guard let handler, handler.hotKeyActivationStyle.allowsDoubleTap else { return }
    guard !handler.handsFreeArmsHotKey else { return }
    guard handler.activeSessionGesture == .doubleTap else { return }
    await handler.endGestureSession(trigger: .singleTap)
  }

  /// Double-tap toggles: it arms hands-free dictation when that mode is on,
  /// otherwise it starts a session or ends the one it started.
  func handleDoubleTap(
    triggerTiming: SessionTriggerTiming,
    primedInput: PrimedLiveInputReservation?,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) async {
    guard let handler else { return }
    guard handler.hotKeyActivationStyle.allowsDoubleTap,
      now - lastDoubleTapEventUptime >= Self.doubleTapDebounce
    else {
      handler.releasePrimedInput(primedInput)
      return
    }
    lastDoubleTapEventUptime = now

    if await handler.handleHandsFreeHotKey() {
      handler.releasePrimedInput(primedInput)
      return
    }

    if let gesture = handler.activeSessionGesture {
      handler.releasePrimedInput(primedInput)
      guard gesture == .doubleTap else { return }
      await handler.endGestureSession(trigger: .doubleTap)
    } else {
      await handler.startGestureSession(trigger: .doubleTap, triggerTiming: triggerTiming, primedInput: primedInput)
    }
  }
}
