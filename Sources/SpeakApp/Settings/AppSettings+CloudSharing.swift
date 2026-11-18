import Foundation
import SpeakCore

/// What the macOS dictation workflow sends to cloud AI providers, for the
/// consent gate (issue #1805). Mirrors the routes a session actually takes:
/// the selected transcription model, post-processing when enabled, and live
/// polish in Auto-Clean live mode.
extension AppSettings {
  var privacyWorkflowSummary: PrivacyWorkflowSummary {
    let usesBatch = transcriptionMode != .liveNative
    let batchModel = transcriptionMode == .localModel ? localTranscriptionModel : batchTranscriptionModel
    return PrivacyWorkflowSummary.make(
      PrivacyWorkflowInputs(
        usesBatchTranscription: usesBatch,
        liveTranscriptionModelID: liveTranscriptionModel,
        batchTranscriptionModelID: batchModel,
        postProcessingEnabled: postProcessingEnabled,
        postProcessingModelID: postProcessingModel,
        voiceOutputEnabled: false,
        voiceOutputProvider: .deepgram
      )
    )
  }

  /// The model live polish rewrites with, or nil when it does not run.
  var activeLivePolishModel: String? {
    guard transcriptionMode == .liveNative, speedMode.usesLivePolish else { return nil }
    return LivePolishPolicy.model(configured: livePolishModel, postProcessing: postProcessingModel)
  }

  /// Every provider a dictation started now would send content to.
  var dictationCloudSharingRequests: [CloudSharingRequest] {
    var requests = CloudSharingConsent.requests(for: privacyWorkflowSummary)
    if let polish = activeLivePolishModel,
      let request = CloudSharingConsent.request(forModel: polish, purpose: .postProcessing) {
      requests.append(request)
    }
    return CloudSharingConsent.merged(requests)
  }

  /// "Use on-device instead": moves every cloud step asked about on device.
  /// Transcription switches to Apple Speech, cloud cleanup and live polish
  /// turn off and read aloud uses the system voice. Steps that already run
  /// on device are left alone.
  func moveCloudStepsOnDevice(_ requests: [CloudSharingRequest]) {
    let summary = privacyWorkflowSummary
    let ids = Set(requests.map(\.provider.id))
    if let id = summary.transcription.providerID, ids.contains(id) {
      selectLocalTranscriptionSource(.apple)
    }
    if let id = summary.postProcessing.providerID, ids.contains(id) {
      postProcessingEnabled = false
    }
    if let polish = activeLivePolishModel,
      let request = CloudSharingConsent.request(forModel: polish, purpose: .postProcessing),
      ids.contains(request.provider.id) {
      speedMode = .instant
    }
    if requests.contains(where: { $0.kinds.contains(.textToSpeak) }) {
      defaultTTSVoice = TextToSpeechManager.onDeviceVoiceID
    }
  }
}
