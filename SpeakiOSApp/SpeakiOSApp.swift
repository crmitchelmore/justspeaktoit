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
    @StateObject private var deepLinkRouter = DeepLinkRouter.shared

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .tint(.brandAccent)
                .environmentObject(deepLinkRouter)
                .onOpenURL { url in
                    deepLinkRouter.handle(url)
                }
        }
    }
}

/// Root tab view with Transcription and OpenClaw tabs.
struct MainTabView: View {
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    var body: some View {
        TabView(selection: $deepLinkRouter.selectedTab) {
            NavigationStack {
                ContentView()
            }
            .tabItem {
                Label("Transcribe", systemImage: "mic.fill")
            }
            .tag(0)

            OpenClawTabView()
                .tabItem {
                    Label("OpenClaw", systemImage: "bolt.horizontal.icloud.fill")
                }
                .tag(1)
        }
    }
}

/// Wraps the OpenClaw tab with its own NavigationStack and deep-link navigation.
struct OpenClawTabView: View {
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @ObservedObject private var store = ConversationStore.shared
    @State private var selectedConversation: OpenClawClient.Conversation?
    @State private var showConversation = false

    var body: some View {
        NavigationStack {
            ConversationListView()
                .navigationDestination(isPresented: $showConversation) {
                    OpenClawChatView(conversation: selectedConversation)
                }
        }
        .onChange(of: deepLinkRouter.pendingConversationId) { _, newId in
            navigateToPendingConversation(id: newId)
        }
        .onAppear {
            // Handle deep link that arrived before this view appeared
            if let pending = deepLinkRouter.pendingConversationId {
                navigateToPendingConversation(id: pending)
            }
        }
    }

    private func navigateToPendingConversation(id: String?) {
        guard let cid = id else { return }
        deepLinkRouter.pendingConversationId = nil

        if let conv = store.conversations.first(where: { $0.id == cid }) {
            selectedConversation = conv
        } else {
            // Conversation not found — open a new one
            selectedConversation = nil
        }
        showConversation = true
    }
}
