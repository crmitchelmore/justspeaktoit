import SpeakCore
import Foundation

/// Builds the collaborators `MainManager` owns, wired to the state they read.
extension MainManager {
  func makeRetirementSteps() -> SessionRetirement.Steps {
    SessionRetirement.Steps(
      finishAutomationCapture: { [weak self] id in
        self?.historyManager.finishAutomationCapture(id: id, item: nil)
      },
      restoreProfile: { [weak self] in
        guard let self else { return }
        self.profileApplier.end(settings: self.appSettings, postProcessing: self.postProcessingManager)
      },
      resumeCaptureWarming: { [weak self] in self?.captureWarmer?.sessionDidEnd() },
      releaseDictationCapture: { [weak self] in self?.captureOwnership.release(.dictation) },
      resumeKeyPressPriming: { [weak self] in self?.keyPressPrimer.sessionDidEnd() }
    )
  }

  func makeKeyPressPrimer() -> KeyPressPrimerRuntime {
    KeyPressPrimerRuntime(
      context: KeyPressPrimerRuntime.Context(
        settings: appSettings,
        hotKeys: hotKeyManager,
        devices: audioInputDeviceManager,
        permissions: permissionsManager,
        transcription: transcriptionManager,
        profiles: profileStore,
        audioFiles: audioFileManager,
        sessionIsIdle: { [weak self] in
          guard let self else { return false }
          return self.activeSession == nil
            && !self.captureStarting
            && !self.migrationInProgress
            && !self.handsFreeArmsHotKey
            && self.captureOwnership.owner == nil
        }
      )
    )
  }

  func makeCaptureHealthMonitor() -> CaptureHealthMonitor {
    CaptureHealthMonitor(
      permissions: permissionsManager,
      devices: audioInputDeviceManager,
      settings: appSettings,
      hud: hudManager
    )
  }
}
