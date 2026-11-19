#if os(iOS)
import Foundation
import SpeakCore

extension TranscriberCoordinator {
    /// Runs before the microphone opens, so a refusal loses no audio (#1805).
    func requireCloudSharingConsent(modelID: String, usesBatch: Bool, runID: UUID) throws {
        guard let cloudSharingConsent else { return }
        let settings = AppSettings.shared
        let transcription = CloudSharingConsent.request(
            forModel: modelID, purpose: usesBatch ? .batchTranscription : .liveTranscription
        )
        let polish = settings.postProcessingEnabled
            ? CloudSharingConsent.request(forModel: settings.postProcessingModel, purpose: .postProcessing)
            : nil
        do {
            try cloudSharingConsent.require(CloudSharingConsent.merged([transcription, polish].compactMap { $0 }))
        } catch {
            observation.finishStartup(runID, error: error)
            finishPresentation()
            throw error
        }
    }
}
#endif
