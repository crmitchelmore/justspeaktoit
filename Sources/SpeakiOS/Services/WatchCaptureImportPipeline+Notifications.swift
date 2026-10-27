#if os(iOS)
import Foundation

extension WatchCaptureImportPipeline {
    /// Called only after both durable History and successful import journal commits.
    func notifySavedResult(_ item: iOSHistoryItem) {
        self.notifyTranscriptReady(TranscriptReadyNotificationInput(
            historyID: item.id,
            transcriptIsEmpty: item.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isForeground: self.applicationIsForeground(),
            matchingResultActivity: self.matchingResultActivity(item.id.uuidString)
        ))
    }
}
#endif
