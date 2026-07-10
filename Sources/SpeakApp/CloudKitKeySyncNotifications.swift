import AppKit
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
                print("[AppDelegate] CloudKit API-key notification sync failed: \(error.localizedDescription)")
            }
        }
    }
}
