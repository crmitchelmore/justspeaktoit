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
        startCapture: { [weak self] preRoll in
          guard let self else { return .rejected(.captureFailed) }
          return await self.startSession(trigger: .handsFree, preRollBuffers: preRoll)
        },
        stopCapture: { [weak self] in
          guard let self else { return .failed(.captureFailed) }
          // The session may already have ended, or be ending, by another route
          // — the user pressed stop, or the app hit its own limit. That is a
          // capture that ended cleanly, not a failed one, so hands-free stays
          // armed instead of reporting a failure after every utterance.
          guard !self.isEndingSession, let session = self.activeSession else {
            return .completed
          }
          await self.endSession(trigger: .handsFree)
          return session.outputDelivered == nil ? .failed(.captureFailed) : .completed
        },
        cancelCapture: { [weak self] in
          self?.userRequestedStopDueToError()
        },
        silenceDuration: { [weak self] in
          self?.appSettings.silenceDuration ?? HandsFreeDictationPolicy.defaultSilenceHoldSeconds
        },
        captureIsSupported: { [weak self] in
          guard let self else { return false }
          return HandsFreeDictationPolicy.supportsCapture(
            modelID: self.appSettings.liveTranscriptionModel,
            isStreaming: self.appSettings.transcriptionMode == .liveNative
          )
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
    setHandsFreeState(state)
    switch state {
    case .arming:
      guard activeSession == nil else { return }
      hudManager.beginArmed(subheadline: "Preparing on-device detector")
    case .armed:
      // Only claim the HUD between utterances; the recording phase owns it
      // while capture is running.
      guard activeSession == nil else { return }
      hudManager.beginArmed()
    case .off:
      if case .armed = hudManager.snapshot.phase {
        hudManager.hide()
      }
    case .recording, .finalising:
      break
    }
  }

  private func presentHandsFreeFailure(_ message: String) {
    lastErrorMessage = message
    hudManager.finishFailure(headline: "Hands-free dictation stopped", message: message)
  }
}
