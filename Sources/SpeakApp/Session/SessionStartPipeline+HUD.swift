import Foundation
import SpeakCore

/// When a starting session's HUD appears (#611): before a slow input-node
/// build it needs to cover, otherwise while the recorder opens.
extension SessionStartPipeline {
  /// Decides how the HUD accompanies this start, presenting it now when a slow
  /// input-node build needs covering. The panel renders on the main run loop,
  /// which the capture start used to wait behind.
  func beginStartingHUD(for request: Request, buildsInputNode: Bool) -> HUDDuringStart {
    let shows = showsRecordingHUD(for: request)
    let beforeInputBuild = shows && StartingHUDTiming.presentsBeforeInputBuild(
      buildsInputNode: buildsInputNode, hasPrimedInput: request.primedInput != nil
    )
    if beforeInputBuild {
      presentStartingHUD(for: request.captureSource)
    }
    return HUDDuringStart(shows: shows, presentsWhileOpening: shows && !beforeInputBuild)
  }

  /// Whether this session shows a HUD (the full/compact dictation HUD, or the
  /// subtle top-right background pill for system-audio captures).
  func showsRecordingHUD(for request: Request) -> Bool {
    // System audio captures always show the subtle corner pill as a privacy
    // indicator without interrupting the user's screen with the main HUD.
    if request.captureSource.includesSystemAudio { return true }
    return showsRecordingHUD(for: request.trigger)
  }

  /// Whether this foreground session shows the HUD.
  func showsRecordingHUD(for trigger: SessionTriggerSource) -> Bool {
    // A hands-free capture always moves the HUD to the recording pane, even
    // when the user hides the HUD for their own sessions: the armed pane
    // otherwise claims the app only listens while it in fact records.
    // Showing that the microphone captures is a privacy duty, not a taste.
    settings.showHUDDuringSessions || trigger == .handsFree
  }

  /// Shows either the subtle background pill (for system/call audio) or the
  /// standard "Getting ready" HUD (for microphone dictation).
  func presentStartingHUD(for captureSource: AudioCaptureSource = .mic) {
    if captureSource.includesSystemAudio {
      hud.beginBackgroundRecording(source: captureSource)
      return
    }
    hud.updateCaptureHealth(owners.captureHealth.snapshot())
    hud.beginRecording(profileName: owners.profileApplier.activeProfileName, awaitingAudio: true)
  }

  /// How the capture step treats the HUD.
  struct HUDDuringStart {
    /// The session shows the HUD, so its health is refreshed once capture is live.
    let shows: Bool
    /// The HUD is presented while the recorder opens rather than before.
    let presentsWhileOpening: Bool
  }
}
