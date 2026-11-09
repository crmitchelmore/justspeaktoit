import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    static var userCancelledRecordingReason: String { "Recording cancelled. Audio retained." }

    /// Captures `keepAudioOnCancel` when the user cancels a recording.
    func noteUserCancelledRecording(_ id: UUID?) {
        let keep = settings.configuration?.keepAudioOnCancel ?? SpeechDefaults.keepAudioOnCancel
        discardCancelledRecordingID = keep ? nil : id
    }

    /// Shows a cancelled recording, or deletes its audio and History record
    /// through the History deletion path when the user chose not to keep it.
    /// Capture failures and app-closing stops carry other reasons and are kept.
    func presentCancelledRecording(_ record: DesktopRecordingStore.Record) async {
        guard discardCancelledRecordingID == record.id else {
            present(record, output: nil)
            return
        }
        discardCancelledRecordingID = nil
        guard !closed, record.failure == Self.userCancelledRecordingReason else {
            present(record, output: nil)
            return
        }
        do {
            if let delete = cloudSync.deleteHistory {
                try await delete(record.id, true)
            } else {
                try await store.delete(id: record.id, deleteAudio: true)
            }
        } catch {
            present(record, output: nil)
            update("Recording cancelled. Audio could not be deleted: \(error.localizedDescription)", state: 0)
            return
        }
        guard await store.isDeleted(id: record.id) else {
            present(record, output: nil)
            return
        }
        discardDeletedHistory(record.id)
        cloudSync.historyChanged?()
        guard !closed else { return }
        refreshHistory()
        let status = "Recording cancelled. Audio discarded."
        finishHUD(record.id, .success(status))
        update(status, transcript: "", state: 0)
    }
}
