import Foundation

/// Build-time feature flags for the iOS app.
///
/// Flags are resolved from Swift active compilation conditions by `Project.swift`.
enum FeatureFlags {
    /// Whether the custom keyboard extension (in-keyboard dictation with the
    /// Instant Dictation handoff) is included. TestFlight includes it by
    /// default; `TUIST_IOS_KEYBOARD=0` is the build-based rollback switch.
    /// Direct capture has a separate gate below.
    static var iOSKeyboardEnabled: Bool {
        #if IOS_KEYBOARD_FEATURE
        true
        #else
        false
        #endif
    }

    /// Whether this build permits microphone capture inside the keyboard
    /// extension. The keyboard can ship independently in handoff-only mode.
    static var iOSKeyboardDirectCaptureEnabled: Bool {
        #if IOS_KEYBOARD_DIRECT_CAPTURE
        true
        #else
        false
        #endif
    }

    /// Whether the Apple Watch companion app (and the iPhone-side
    /// WatchConnectivity capture receiver) are enabled. Defaults to `false`;
    /// `Project.swift` includes the watch app target and defines
    /// `WATCH_APP_FEATURE` only when generated with `TUIST_WATCH_APP=1`.
    static var watchCaptureEnabled: Bool {
        #if WATCH_APP_FEATURE
        true
        #else
        false
        #endif
    }

}
