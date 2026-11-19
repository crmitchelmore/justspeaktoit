import Foundation

/// When a starting session's HUD appears (#611): before a slow input-node
/// build it needs to cover, otherwise while the recorder opens.
extension SessionStartPipeline {
  /// Decides how the HUD accompanies this start, presenting it now when a slow
  /// input-node build needs covering. The panel renders on the main run loop,
  /// which the capture start used to wait behind.
  func beginStartingHUD(for request: Request, buildsInputNode: Bool) -> HUDDuringStart {
    let shows = showsRecordingHUD(for: request.trigger)
    let beforeInputBuild = shows && StartingHUDTiming.presentsBeforeInputBuild(
      buildsInputNode: buildsInputNode, hasPrimedInput: request.primedInput != nil
    )
    if beforeInputBuild {
      presentStartingHUD()
    }
    return HUDDuringStart(shows: shows, presentsWhileOpening: shows && !beforeInputBuild)
  }

  /// Whether this session shows the HUD.
  func showsRecordingHUD(for trigger: SessionTriggerSource) -> Bool {
    // A hands-free capture always moves the HUD to the recording pane, even
    // when the user hides the HUD for their own sessions: the armed pane
    // otherwise claims the app only listens while it in fact records.
    // Showing that the microphone captures is a privacy duty, not a taste.
    settings.showHUDDuringSessions || trigger == .handsFree
  }

  /// Shows the HUD as "Getting ready"; its clock starts only when the
  /// microphone delivers real audio, never while words can't be heard. Uses
  /// the cached microphone status: each TCC query costs 13-35 ms before
  /// capture (#611), and the capture start makes the authoritative check; the
  /// HUD health is refreshed once capture is live.
  func presentStartingHUD() {
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
