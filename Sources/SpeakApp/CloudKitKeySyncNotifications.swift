import AppKit
import SpeakCore
import SpeakSync

extension AppDelegate {
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
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
