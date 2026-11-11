import AppKit
import SpeakCore
import SpeakSync

extension AppDelegate {
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        // The history subscription's push was created on both platforms but
        // handled on neither, so a phone capture reached a running Mac only at
        // its next launch (issue #1007).
        if HistorySyncPushRouting.isHistoryChange(userInfo as [AnyHashable: Any]) {
            Task { @MainActor in await HistorySyncEngine.shared.sync() }
            return
        }
        Task { @MainActor in
            do {
                try await CloudKitKeySync.shared.handleRemoteNotification()
            } catch {
                SpeakLogger.sync.error(
                    "CloudKit API-key notification sync failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
