import SpeakCore
import SwiftUI

/// The main window's content on a normal launch: a loading view that
/// bootstraps the environment, then onboarding or the main view.
///
/// `SpeakApp` keeps the persisted launch flags and passes them in as bindings,
/// so moving this out of the scene does not change who owns that state.
struct SpeakLaunchContent: View {
    @ObservedObject var environmentHolder: EnvironmentHolder
    let appDelegate: AppDelegate
    @Binding var hasCompletedOnboarding: Bool
    @Binding var hasAnsweredAnalyticsConsent: Bool
    @Binding var showingAnalyticsConsent: Bool
    let openMainWindow: () -> Void

    var body: some View {
        Group {
            if let environment = environmentHolder.environment {
                if hasCompletedOnboarding {
                    mainContent(environment)
                } else {
                    onboardingContent(environment)
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        environmentHolder.bootstrap()
                        environmentHolder.environment?.reopenMainWindow = openMainWindow
                    }
            }
        }
    }

    private func mainContent(_ environment: AppEnvironment) -> some View {
        MainView()
            .environmentObject(environment)
            .environmentObject(environment.settings)
            .environmentObject(environment.paidAccess)
            .environmentObject(environment.history)
            .environmentObject(environment.personalLexicon)
            .environmentObject(environment.audioDevices)
            .environmentObject(environment.tts)
            .environmentObject(environment.shortcuts)
            .environmentObject(environment.recordingControl)
            .onAppear {
                appDelegate.environment = environment
                environment.configureShortcutHandlers()
                environment.installMenuBar()
                environment.installDockMenu()
                environment.installServices()
                if #available(macOS 10.12.2, *) {
                    environment.installTouchBar()
                }
                if environment.analyticsAvailable,
                   !hasAnsweredAnalyticsConsent {
                    showingAnalyticsConsent = true
                }
            }
            .alert(
                "Help improve \(ReleaseTrain.current.displayName)?",
                isPresented: $showingAnalyticsConsent
            ) {
                Button("Share Anonymous Analytics") {
                    hasAnsweredAnalyticsConsent = true
                    environment.settings.analyticsEnabled = true
                }
                Button("Not Now", role: .cancel) {
                    hasAnsweredAnalyticsConsent = true
                    environment.settings.analyticsEnabled = false
                }
            } message: {
                Text(
                    "Share anonymous usage and reliability data. "
                        + "We never collect transcripts, audio, prompts, clipboard text, "
                        + "keystrokes, API keys, screen content, or personal identity. "
                        + "You can turn this off at any time in Settings."
                )
            }
    }

    private func onboardingContent(_ environment: AppEnvironment) -> some View {
        OnboardingView(
            permissionsManager: environment.permissionsManager,
            secureStorage: environment.secureStorage,
            settings: environment.settings,
            hotKeyManager: environment.hotKeys,
            audioFileManager: environment.audio,
            transcriptionManager: environment.transcription,
            isComplete: $hasCompletedOnboarding
        )
        .onAppear {
            appDelegate.environment = environment
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if completed {
                // Re-run transcription provider config after onboarding
                // to pick up any API keys the user just set
                Task {
                    await WireUp.configureDefaultTranscriptionProvider(
                        settings: environment.settings,
                        secureStorage: environment.secureStorage
                    )
                }
            }
        }
    }
}
