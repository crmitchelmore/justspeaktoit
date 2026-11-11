import SpeakCore
import Foundation

/// Decides whether hands-free dictation may act on the session that is active
/// right now.
///
/// A hands-free capture can end out of band: the user presses stop, and the
/// detector only learns about it when its silence hold elapses. By then the
/// user may already record again by hand. Hands-free therefore ends and cancels
/// captures it started, and nothing else.
enum HandsFreeCaptureOwnership {
  static func ownsSession(_ session: ActiveSession?, isEndingSession: Bool) -> Bool {
    guard !isEndingSession, let session else { return false }
    return session.trigger == .handsFree
  }
}

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
          // Hands-free ends only the capture it started. The session may have
          // ended by another route — the user pressed stop, or the app hit its
          // own limit — and the user may already record again by hand. Either
          // way this capture is over and ended cleanly, so hands-free stays
          // armed rather than reporting a failure after every utterance.
          guard
            HandsFreeCaptureOwnership.ownsSession(
              self.activeSession,
              isEndingSession: self.isEndingSession
            ),
            let session = self.activeSession
          else {
            return .completed
          }
          await self.endSession(trigger: .handsFree)
          return session.outputDelivered == nil ? .failed(.captureFailed) : .completed
        },
        cancelCapture: { [weak self] in
          guard let self else { return }
          // Same rule for the cancel path: never stop a recording that
          // hands-free did not start.
          guard
            HandsFreeCaptureOwnership.ownsSession(
              self.activeSession,
              isEndingSession: self.isEndingSession
            )
          else { return }
          self.userRequestedStopDueToError()
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
