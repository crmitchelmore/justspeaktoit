#if os(iOS)
import Foundation
import SpeakCore

extension TranscriptionRecordingService {
    /// True when this start will show the consent sheet. Already-allowed and on-device models do not.
    func cloudSharingNeedsPrompt(modelID: String, usesBatch: Bool) -> Bool {
        let purpose: ModelCredentialPurpose = usesBatch ? .batchTranscription : .liveTranscription
        guard let request = CloudSharingConsent.request(
            forModel: modelID, purpose: purpose, availability: cloudSharingAvailability
        ) else { return false }
        return !CloudSharingConsentStore.shared.allows(request)
    }

    /// Asks before a cloud model can hear the microphone. On-device switches the saved choice
    /// and this run uses that model. Not now unwinds the start and uploads nothing.
    func consentedCloudModel(
        modelID: String, usesBatch: Bool, run: UUID
    ) async throws -> (modelID: String, usesBatch: Bool) {
        let purpose: ModelCredentialPurpose = usesBatch ? .batchTranscription : .liveTranscription
        switch await CloudSharingPrompt.resolve(
            modelID: modelID, purpose: purpose, availability: cloudSharingAvailability
        ) {
        case .proceed:
            return (modelID, usesBatch)
        case .useOnDevice:
            settings.selectTranscriptionLocation(.local)
            let batch = settings.transcriptionMode == .batch
            let model = batch ? settings.batchTranscriptionModel : settings.selectedModel
            return (model, batch)
        case .refused(let request):
            unwindCancelledStart(outcome: .failed, run: run)
            throw CloudSharingBlocked(request: request)
        }
    }

    private var cloudSharingAvailability: CloudSharingOnDeviceAvailability {
        CloudSharingOnDeviceAvailability(
            transcription: true,
            postProcessing: AppleFoundationModelPolisher.isAvailable,
            voice: false
        )
    }
}
#endif
