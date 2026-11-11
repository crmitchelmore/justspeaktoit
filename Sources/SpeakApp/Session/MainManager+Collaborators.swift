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
        self.profileApplier.end(settings: self.appSettings, postProcessing: self.text.postProcessing)
      },
      resumeCaptureWarming: { [weak self] in self?.captureWarmer.sessionDidEnd() },
      releaseDictationCapture: { [weak self] in self?.captureOwnership.release(.dictation) },
      resumeKeyPressPriming: { [weak self] in self?.keyPressPrimer.sessionDidEnd() }
    )
  }

  func makeKeyPressPrimer() -> KeyPressPrimerRuntime {
    KeyPressPrimerRuntime(
      context: KeyPressPrimerRuntime.Context(
        settings: appSettings,
        hotKeys: capture.hotKeys,
        devices: capture.devices,
        permissions: capture.permissions,
        transcription: transcriptionManager,
        profiles: capture.profiles,
        audioFiles: capture.audioFiles,
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
      permissions: capture.permissions,
      devices: capture.devices,
      settings: appSettings,
      hud: hudManager
    )
  }

  func makeCaptureRuntime() -> SessionCaptureRuntime {
    let audioFiles = capture.audioFiles
    return SessionCaptureRuntime(
      context: SessionCaptureRuntime.Context(
        meterReading: { audioFiles.getCurrentMeterReading() },
        silenceSettings: { [appSettings] in
          SilenceAutoStop.Settings(
            enabled: appSettings.silenceDetectionEnabled,
            threshold: appSettings.silenceThreshold,
            duration: appSettings.silenceDuration
          )
        },
        isRecording: { [weak self] in self?.state == .recording },
        // Hands-free captures end on the speech detector's own silence hold.
        // Two owners of the same stop race each other, and the loser then
        // reports a failed session after every utterance.
        silenceStopEligible: { [weak self] in
          self?.activeSession.map { $0.trigger != .handsFree } ?? false
        },
        updateAudioLevel: { [hudManager] in hudManager.updateAudioLevel($0) },
        markAudioLive: { [hudManager] in _ = hudManager.markAudioLive() },
        playCue: { [weak self] session in
          guard let self else { return }
          self.startPipeline.playStartCue(for: session, isRecording: self.state == .recording)
        },
        silenceElapsed: { [weak self] in
          Task { await self?.endSession(trigger: .silenceDetection) }
        }
      )
    )
  }

  func makeStartPipeline() -> SessionStartPipeline {
    let pipeline = SessionStartPipeline(
      settings: appSettings,
      capture: capture,
      transcription: transcriptionManager,
      postProcessing: text.postProcessing,
      hud: hudManager,
      owners: SessionStartPipeline.Owners(
        captureRuntime: captureRuntime,
        captureHealth: captureHealth,
        keyPressPrimer: keyPressPrimer,
        captureWarmer: captureWarmer,
        captureOwnership: captureOwnership,
        retirement: sessionRetirement,
        profileApplier: profileApplier,
        soundPlayer: recordingSoundPlayer
      )
    )
    pipeline.host = self
    return pipeline
  }

  func makeReprocessingCoordinator() -> ReprocessingCoordinator {
    let coordinator = ReprocessingCoordinator(
      settings: appSettings,
      permissions: capture.permissions,
      transcription: transcriptionManager,
      text: text,
      history: historyManager,
      hud: hudManager
    )
    coordinator.host = self
    return coordinator
  }
}
