import SpeakCore
import SwiftUI

@main
struct SpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environmentHolder = EnvironmentHolder()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasAnsweredAnalyticsConsent") private var hasAnsweredAnalyticsConsent = false
    @State private var showingAnalyticsConsent = false
    @Environment(\.openWindow) private var openWindow

    init() {
        Self.skipWindowRestorationAfterCrashes()
        // A Sparkle smoke run (scripts/sparkle-update-smoke.sh) is headless and
        // throw-away: no crash reporting, no windows, no onboarding. Bail out
        // before anything else initialises.
        guard !SparkleSmokeSession.isActive else { return }
        // Crash reporting starts as early as possible, but only with consent.
        SentryManager.start()
        SentryManager.observeConsent()
    }

    var body: some Scene {
        WindowGroup(ReleaseTrain.current.displayName, id: "main") {
            Group {
                if SparkleSmokeSession.isActive {
                    // A zero-size placeholder: SwiftUI still needs a scene, but
                    // the smoke run must not bootstrap the environment, show
                    // onboarding, or install the HUD and menu bar.
                    Color.clear.frame(width: 1, height: 1)
                } else {
                    // Bound the scene's generic metadata before SwiftUI creates its graph.
                    AnyView(SpeakLaunchContent(
                        environmentHolder: environmentHolder,
                        appDelegate: appDelegate,
                        hasCompletedOnboarding: $hasCompletedOnboarding,
                        hasAnsweredAnalyticsConsent: $hasAnsweredAnalyticsConsent,
                        showingAnalyticsConsent: $showingAnalyticsConsent,
                        openMainWindow: { openWindow(id: "main") }
                    ))
                }
            }
            .tint(.brandAccent)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            if let environment = environmentHolder.environment {
                SpeakCommands(environment: environment)
            }
        }
    }
}

extension SpeakApp {
    /// After the app crashes, AppKit's window restoration asks with a modal
    /// alert whether to reopen windows. It blocks the main thread before the
    /// automation service starts, so `speak` gets no reply until someone clicks
    /// it (#1464). Ignoring saved window state skips that prompt; the main
    /// window opens fresh. Registered, not set, so an explicit default still wins.
    static func skipWindowRestorationAfterCrashes(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["ApplePersistenceIgnoreState": true])
    }
}
