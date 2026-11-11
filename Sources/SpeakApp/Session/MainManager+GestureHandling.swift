import Foundation
import SpeakCore
import SpeakHotKeys

/// The session surface `SessionGestureRouter` drives.
extension MainManager: SessionGestureHandling {
  var hotKeyActivationStyle: AppSettings.HotKeyActivationStyle {
    appSettings.hotKeyActivationStyle
  }

  var activeSessionGesture: HistoryTrigger.HotKeyGesture? {
    activeSession?.gesture
  }

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

  func releasePrimedInput(_ primedInput: PrimedLiveInputReservation?) {
    keyPressPrimer.release(primedInput)
  }

  func startGestureSession(
    trigger: SessionTriggerSource,
    triggerTiming: SessionTriggerTiming,
    primedInput: PrimedLiveInputReservation?
  ) async {
    await startSession(trigger: trigger, triggerTiming: triggerTiming, primedInput: primedInput)
  }

  func endGestureSession(trigger: SessionTriggerSource) async {
    await endSession(trigger: trigger)
  }
}
