import SwiftUI
import SpeakiOSLib
import UIKit

final class SpeakiOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            return !handleQuickAction(shortcutItem, application: application)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(handleQuickAction(shortcutItem, application: application))
    }

    private func handleQuickAction(_ shortcutItem: UIApplicationShortcutItem, application: UIApplication) -> Bool {
        guard shortcutItem.type == HomeScreenQuickAction.transcribe else { return false }

        let backgroundTask = application.beginBackgroundTask(withName: "HomeScreenQuickActionTranscribe")
        Task { @MainActor in
            defer {
                if backgroundTask != .invalid {
                    application.endBackgroundTask(backgroundTask)
                }
            }
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
            MainTabView()
                .tint(.brandAccent)
        }
    }
}

/// Root tab view with Transcription and OpenClaw tabs.
struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ContentView()
            }
            .tabItem {
                Label("Transcribe", systemImage: "mic.fill")
            }
            .tag(0)

            NavigationStack {
                ConversationListView()
            }
            .tabItem {
                Label("OpenClaw", systemImage: "bolt.horizontal.icloud.fill")
            }
            .tag(1)
        }
    }
}
