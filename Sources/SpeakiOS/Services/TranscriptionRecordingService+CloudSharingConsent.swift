#if os(iOS)
import Foundation
import SpeakCore

/// The recording start's consent check (issue #1805).
@MainActor
extension TranscriptionRecordingService {
    /// The providers a run on `currentModel` would send content to.
    func cloudSharingRequests(usesBatch: Bool, polishModel: String?) -> [CloudSharingRequest] {
        let transcription = CloudSharingConsent.request(
            forModel: currentModel, purpose: usesBatch ? .batchTranscription : .liveTranscription
        )
        let polish = polishModel.flatMap { CloudSharingConsent.request(forModel: $0, purpose: .postProcessing) }
        return CloudSharingConsent.merged([transcription, polish].compactMap { $0 })
    }

    /// Refuses the start before the microphone opens, so nothing is lost. The
    /// app shows the sheet; a Shortcut, the keyboard or the Action Button
    /// reports the error, which tells the user to open the app.
    func requireCloudSharingConsent(usesBatch: Bool, polishModel: String?, run: UUID) throws {
        guard let prompt = dependencies.cloudSharingConsent else { return }
        do {
            try prompt.require(cloudSharingRequests(usesBatch: usesBatch, polishModel: polishModel))
        } catch {
            unwindCancelledStart(outcome: .failed, run: run)
            throw error
        }
    }
}
#endif
