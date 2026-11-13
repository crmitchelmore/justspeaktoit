#if os(iOS)
import AppIntents

/// Registers the library's App Intents so the containing app can include them.
/// The app's `AppShortcutsProvider` must live in the app target: Xcode merges
/// a static library's actions into the app but drops its `autoShortcuts`.
public struct SpeakiOSAppIntentsPackage: AppIntentsPackage {}
#endif
