import Foundation
import SpeakCore
import SpeakHotKeys

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
