#if os(iOS)
import Foundation
import SpeakCore

extension TranscriptionRecordingService {
    /// Asks before a cloud model can hear the microphone. On-device switches the saved choice
    /// and this run uses that model. Not now unwinds the start and uploads nothing.
    func consentedCloudModel(
        modelID: String, usesBatch: Bool, run: UUID
    ) async throws -> (modelID: String, usesBatch: Bool) {
        let purpose: ModelCredentialPurpose = usesBatch ? .batchTranscription : .liveTranscription
        let availability = CloudSharingOnDeviceAvailability(
            transcription: true,
            postProcessing: AppleFoundationModelPolisher.isAvailable,
            voice: false
        )
        switch await CloudSharingPrompt.resolve(
            modelID: modelID, purpose: purpose, availability: availability
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
}
#endif
