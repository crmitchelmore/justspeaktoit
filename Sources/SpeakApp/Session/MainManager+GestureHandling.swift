import Foundation
import SpeakCore

/// The session surface `SessionGestureRouter` drives.
extension MainManager: SessionGestureHandling {
  var hotKeyActivationStyle: AppSettings.HotKeyActivationStyle {
    appSettings.hotKeyActivationStyle
  }

  var activeSessionGesture: HistoryTrigger.HotKeyGesture? {
    activeSession?.gesture
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
