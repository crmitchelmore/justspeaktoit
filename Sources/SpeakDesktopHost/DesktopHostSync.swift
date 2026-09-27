import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync

extension DesktopHostController {
    package func installCloudSync(_ hooks: DesktopHostSyncHooks) {
        cloudSync = hooks
    }

    /// Shows History changes that sync has already saved. Rows update at once;
    /// the displayed transcript is re-rendered only for the selected record and
    /// only while nothing else owns the transcript area. A removed selection is
    /// cleared, so no action can target a record that no longer exists.
    package func applySyncedHistory(_ changes: [DesktopHistorySyncChange]) async {
        guard !closed else { return }
        var selectedChanged = false
        for change in changes {
            switch change {
            case .saved(let id):
                guard let record = await store.existingRecord(id: id) else { continue }
                indexHistory(record)
                selectedChanged = selectedChanged || id == selectedHistoryID
            case .removed(let id):
                history[id] = nil
                historySearchText[id] = nil
                if id == selectedHistoryID {
                    playback.stop(announcing: false)
                    stopReadAloud()
                    selectedHistoryID = nil
                    transcript = ""
                    transcriptVariant = .processed
                    Platform.transcriptVariant(nil, for: nil, switchable: false)
                    update("The selected recording was deleted on another device.", transcript: "")
                }
            case .keptAfterRemoteDeletion:
                continue
            }
        }
        refreshHistory()
        if selectedChanged, canUseHistory, let id = selectedHistoryID, let record = history[id] {
            transcript = record.text(for: transcriptVariant) ?? ""
            Platform.historyPresentation(record, variant: transcriptVariant, status: "Updated from iCloud.")
        }
    }
}
