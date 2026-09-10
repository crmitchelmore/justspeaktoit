import SwiftUI
import SpeakCore
import SpeakiOSLib
import UIKit

final class SpeakiOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // A new app process cannot own the previous process's recording. Reset
        // before launch actions can start a session, never on foreground entry.
        SharedTranscriptionState.shared.clearRecordingState()
        application.registerForRemoteNotifications()
        // Watch file transfers launch the app in the background; the session
        // must be activated during launch so queued captures are delivered.
        if FeatureFlags.watchCaptureEnabled {
            WatchCaptureReceiver.shared.activate()
        }
        Task { @MainActor in
            _ = await AppSettings.shared.syncCloudKitKeys()
        }
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            return !handleQuickAction(shortcutItem, application: application)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let synced = await AppSettings.shared.syncCloudKitKeys()
            completionHandler(synced ? .newData : .noData)
        }
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
            // Shared with capture deep links so the two cannot drift. This used
            // to branch on `isRunning` (so a press during start-up silently did
            // nothing instead of cancelling) and stop with no destination, which
            // copied to the clipboard even for "Save to History Only" users.
            await CaptureCommandRunner.perform(.toggle)
        }
        return true
    }
}

@main
struct SpeakiOSApp: App {
    @UIApplicationDelegateAdaptor(SpeakiOSAppDelegate.self) private var appDelegate
    @ObservedObject private var deepLinkRouter = DeepLinkRouter.shared
    @ObservedObject private var keyboardInstantDictation = KeyboardInstantDictationCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .tint(.brandAccent)
                .environmentObject(deepLinkRouter)
                .environment(\.openClawEnabled, FeatureFlags.openClawTabEnabled)
                .environment(\.iOSKeyboardEnabled, FeatureFlags.iOSKeyboardEnabled)
                .environment(
                    \.iOSKeyboardDirectCaptureEnabled,
                    FeatureFlags.iOSKeyboardDirectCaptureEnabled
                )
                .onOpenURL { url in
                    deepLinkRouter.handle(url)
                    runPendingCaptureAction()
                }
                .task {
                    // A link that cold-launched the app is queued before the
                    // scene is active; drain it once the view is up.
                    runPendingCaptureAction()
                    guard FeatureFlags.iOSKeyboardEnabled else {
                        KeyboardInstantDictationStore.shared.setEnabled(false)
                        return
                    }
                    keyboardInstantDictation.activate()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    runPendingCaptureAction()
                    if FeatureFlags.iOSKeyboardEnabled {
                        keyboardInstantDictation.activate()
                    }
                    // Foreground entry reconciles Watch imports interrupted by
                    // suspension and replays unconfirmed acks (issue #674).
                    if FeatureFlags.watchCaptureEnabled {
                        WatchCaptureReceiver.shared.reconcilePendingWork()
                    }
                }
        }
    }

    /// Performs a capture deep link once the scene is actually active.
    ///
    /// A `justspeaktoit://start` link can cold-launch the app, and the URL
    /// arrives before the scene is foreground enough to open a microphone, so
    /// the router queues the command and this drains it from `onOpenURL`, the
    /// first `task`, and every return to `.active`.
    private func runPendingCaptureAction() {
        guard scenePhase == .active else { return }
        guard let link = deepLinkRouter.consumePendingCaptureAction() else { return }
        Task { @MainActor in
            // The whole link, not just its verb: `dictate` also has to wait for
            // the capture to end and hand the transcript back to the caller.
            await CaptureCommandRunner.perform(link)
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

            if FeatureFlags.openClawTabEnabled {
                OpenClawTabView()
                    .tabItem {
                        Label("OpenClaw", systemImage: "bolt.horizontal.icloud.fill")
                    }
                .tag(1)
            }
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
        .onChange(of: store.isLoaded) { _, loaded in
            guard loaded else { return }
            navigateToPendingConversation(id: deepLinkRouter.pendingConversationId)
        }
    }

    private func navigateToPendingConversation(id: String?) {
        guard let cid = id else { return }
        guard store.isLoaded else { return }

        if let conv = store.conversations.first(where: { $0.id == cid }) {
            selectedConversation = conv
        } else {
            // Conversation not found — open a new one
            selectedConversation = nil
        }

        deepLinkRouter.pendingConversationId = nil
        showConversation = true
    }
}
