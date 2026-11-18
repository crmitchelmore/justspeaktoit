import Foundation
import SpeakCore

/// Asks before a dictation start sends audio to a cloud provider, and switches
/// the saved transcription choice when the user picks on-device.
@MainActor
enum CloudSharingStartConsent {
  /// This start must not fall back from Apple Speech to Apple's servers.
  /// Cleared when the start pipeline returns.
  static var suppressAppleCloudFallback = false

  /// Nil when the start may continue. Otherwise the message to show, and the start must not run.
  static func prepare(settings: AppSettings, trigger: SessionTriggerSource) async -> String? {
    suppressAppleCloudFallback = false
    let model: String
    let purpose: ModelCredentialPurpose
    switch settings.transcriptionMode {
    case .localModel:
      return nil
    case .batchRemote:
      model = settings.batchTranscriptionModel
      purpose = .batchTranscription
    case .liveNative:
      model = settings.liveTranscriptionModel
      purpose = .liveTranscription
    }
    let appleMayUpload = purpose == .liveTranscription && trigger != .handsFree
    switch await CloudSharingPrompt.resolve(
      modelID: model, purpose: purpose, appleSpeechMayUseAppleServers: appleMayUpload
    ) {
    case .proceed:
      return nil
    case .useOnDevice:
      applyOnDeviceTranscription(settings)
      suppressAppleCloudFallback = true
      return nil
    case .refused(let request):
      return CloudSharingConsent.blockedMessage(for: request)
    }
  }

  /// Opens no socket unless this model is allowed. Use on-device changes the saved choice and
  /// refuses this start, so the audio is not streamed.
  static func requireLive(modelID: String, settings: AppSettings) async throws {
    switch await CloudSharingPrompt.resolve(modelID: modelID, purpose: .liveTranscription) {
    case .proceed:
      return
    case .useOnDevice:
      applyOnDeviceTranscription(settings)
      throw CloudSharingKeptOnDevice(modelID: modelID)
    case .refused(let request):
      throw CloudSharingBlocked(request: request)
    }
  }

  /// Selects a downloaded model when one is remembered, otherwise Apple Speech.
  static func applyOnDeviceTranscription(_ settings: AppSettings) {
    let local = settings.localTranscriptionModel
    if ModelRouting.family(for: local).isDownloadedLocal {
      settings.selectLocalTranscriptionSource(.downloaded)
    } else {
      settings.selectLocalTranscriptionSource(.apple)
    }
  }
}
