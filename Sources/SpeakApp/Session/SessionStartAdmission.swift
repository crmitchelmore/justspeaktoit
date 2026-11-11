import SpeakCore
import Foundation

/// The checks a dictation start must pass before a session exists: a
/// hands-free route that supports capture, a stored live API key, a
/// microphone, and the shared capture reservation (Voice Edit may hold it).
/// A rejection undoes what the start already took and says why.
@MainActor
struct SessionStartAdmission {
  let settings: AppSettings
  let capture: SessionCaptureServices
  let transcription: TranscriptionManager
  let hud: HUDManager
  let ownership: CaptureSessionOwnership
  let retirement: SessionRetirement

  /// Checks that must pass before a session exists. Returns the rejection
  /// after undoing the profile and warm-capture hand-off, or nil when the
  /// start may proceed with `.dictation` capture reserved.
  func rejection(for trigger: SessionTriggerSource, host: SessionStartHost) async -> HandsFreeCaptureStartOutcome? {
    if trigger == .handsFree,
      !HandsFreeDictationPolicy.supportsCapture(
        modelID: settings.liveTranscriptionModel,
        isStreaming: settings.transcriptionMode == .liveNative
      ) {
      return abandonStart(.rejected(.unsupportedConfiguration))
    }

    if let alert = await missingLiveAPIKeyAlert() {
      host.publishMissingLiveAPIKey(alert)
      return abandonStart(.rejected(.captureFailed))
    }

    if capture.audioFiles.requiresPhysicalInput && capture.devices.devices.isEmpty {
      let rejection = abandonStart(.rejected(.audioUnavailable))
      showStartFailure(
        "No microphone connected. Plug in a USB or Bluetooth microphone and try again.",
        headline: "No microphone connected",
        message: "Plug in a USB or Bluetooth microphone and try again.",
        host: host
      )
      return rejection
    }

    // Voice Edit may own the shared recorder and live stream right now. Starting
    // on top of it would hit `alreadyRecording` and the failure path would then
    // cancel Voice Edit's capture, so refuse before touching either (issue #673).
    guard ownership.reserve(.dictation) else {
      let rejection = abandonStart(.rejected(.captureFailed))
      showStartFailure(
        "Voice edit is in progress. Finish or cancel it first.",
        headline: "Voice edit in progress",
        message: "Finish or cancel the voice edit, then start dictation.",
        displayDuration: 3,
        host: host
      )
      return rejection
    }
    return nil
  }

  /// No session was created, so `activeSession`'s teardown will not run:
  /// revert the profile and let capture pre-warming resume here.
  private func abandonStart(_ rejection: HandsFreeCaptureStartOutcome) -> HandsFreeCaptureStartOutcome {
    retirement.abandonStart()
    return rejection
  }

  private func showStartFailure(
    _ stateMessage: String,
    headline: String,
    message: String,
    displayDuration: TimeInterval? = nil,
    host: SessionStartHost
  ) {
    host.publishStartRejection(stateMessage)
    hud.finishFailure(headline: headline, message: message, displayDuration: displayDuration)
  }

  /// The alert for a live model whose API key has not been stored, or nil
  /// when the start may go ahead.
  private func missingLiveAPIKeyAlert() async -> MissingLiveAPIKeyAlert? {
    guard settings.transcriptionMode == .liveNative else { return nil }
    guard let missing = await transcription.missingLiveAPIKeyProvider() else { return nil }
    let modelID = settings.liveTranscriptionModel
    let modelName = ModelCatalog.liveTranscription.first { $0.id == modelID }?.displayName ?? modelID
    return MissingLiveAPIKeyAlert(provider: missing, modelDisplayName: modelName)
  }
}
