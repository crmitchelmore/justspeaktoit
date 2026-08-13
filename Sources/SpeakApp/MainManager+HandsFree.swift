import SpeakCore
import Foundation

/// Hands-free ("armed") dictation wiring: the hotkey arms a listening session
/// instead of recording, and Apple's `SpeechDetector` starts and stops capture.
///
/// Everything here is inert unless `appSettings.handsFreeDictationActive` is
/// true, which requires both the default-off setting and macOS 26.
extension MainManager {
  /// Whether the hotkey should arm hands-free dictation rather than record.
  var handsFreeArmsHotKey: Bool {
    appSettings.handsFreeDictationActive
  }

  func makeHandsFreeCoordinator() -> HandsFreeDictationCoordinator {
    HandsFreeDictationCoordinator(
      permissionsManager: permissionsManager,
      audioDeviceManager: audioInputDeviceManager,
      callbacks: HandsFreeDictationCoordinator.Callbacks(
        startCapture: { [weak self] in
          await self?.startSession(trigger: .handsFree)
        },
        stopCapture: { [weak self] in
          await self?.endSession(trigger: .handsFree)
        },
        armedStateChanged: { [weak self] state in
          self?.presentHandsFreeState(state)
        },
        failed: { [weak self] message in
          self?.presentHandsFreeFailure(message)
        }
      )
    )
  }

  /// Handles the hotkey while hands-free dictation is on. Returns true when it
  /// consumed the gesture, so the normal record path is skipped.
  func handleHandsFreeHotKey() async -> Bool {
    guard handsFreeArmsHotKey else { return false }
    await handsFreeCoordinator.toggle()
    return true
  }

  /// Disarms when the user turns hands-free dictation off, so a live detector
  /// never outlives the setting that allowed it.
  func disarmHandsFreeIfDisabled() {
    guard !appSettings.handsFreeDictationActive, handsFreeCoordinator.isArmed else { return }
    Task { [handsFreeCoordinator] in await handsFreeCoordinator.disarm() }
  }

  private func presentHandsFreeState(_ state: HandsFreeDictationMachine.State) {
    switch state {
    case .armedListening:
      // Only claim the HUD between utterances; the recording phase owns it
      // while capture is running.
      guard activeSession == nil else { return }
      hudManager.beginArmed()
    case .disarmed:
      if case .armed = hudManager.snapshot.phase {
        hudManager.hide()
      }
    case .capturing, .coolingDown:
      break
    }
  }

  private func presentHandsFreeFailure(_ message: String) {
    lastErrorMessage = message
    hudManager.finishFailure(headline: "Hands-free dictation stopped", message: message)
  }
}
