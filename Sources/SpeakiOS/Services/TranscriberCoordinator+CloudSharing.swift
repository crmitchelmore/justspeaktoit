#if os(iOS)
import Foundation
import SpeakCore

extension TranscriberCoordinator {
    /// Foreground capture does not go through `TranscriptionRecordingService.startRecording`,
    /// so the consent ask lives here too. A refusal never opens the socket.
    func requireCloudSharingConsent(modelID: String, run: UUID) async throws {
        let settings = AppSettings.shared
        let purpose: ModelCredentialPurpose = settings.transcriptionMode == .batch
            ? .batchTranscription : .liveTranscription
        let availability = CloudSharingOnDeviceAvailability(
            transcription: true,
            postProcessing: AppleFoundationModelPolisher.isAvailable,
            voice: false
        )
        switch await CloudSharingPrompt.resolve(
            modelID: modelID, purpose: purpose, availability: availability
        ) {
        case .proceed:
            return
        case .useOnDevice:
            settings.selectTranscriptionLocation(.local)
            let error = CloudSharingSwitchedOnDevice()
            abandonOwnedStart(error, run: run)
            throw error
        case .refused(let request):
            let error = CloudSharingBlocked(request: request)
            abandonOwnedStart(error, run: run)
            throw error
        }
    }
}
#endif
