import SwiftUI
import SpeakiOSLib
import UIKit

final class SpeakiOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            _ = handleQuickAction(shortcutItem)
            return false
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(handleQuickAction(shortcutItem))
    }

    private func handleQuickAction(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == HomeScreenQuickAction.transcribe else { return false }
        Task { @MainActor in
            let service = TranscriptionRecordingService.shared
            if service.isRunning {
                _ = await service.stopRecording()
            } else {
                do {
                    try await service.startRecording()
                } catch {
                    print("[SpeakiOSAppDelegate] Quick action failed: \(error.localizedDescription)")
                }
            }
        }
        return true
    }
}

@main
struct SpeakiOSApp: App {
    @UIApplicationDelegateAdaptor(SpeakiOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.brandAccent)
        }
    }
}
