import Foundation

/// Build-time feature flags for the iOS app.
///
/// Flags are resolved from Swift active compilation conditions so they can be
/// toggled per build without shipping a runtime setting. Generate the project
/// with the corresponding environment variable to flip a flag, e.g.:
///
///     HIDE_OPENCLAW_TAB=1 tuist generate
///
/// (see `Project.swift`, which maps the env var to the
/// `HIDE_OPENCLAW_TAB` compilation condition).
enum FeatureFlags {
    /// Whether the OpenClaw tab is shown in the main tab bar. Defaults to `true`;
    /// set the `HIDE_OPENCLAW_TAB` build condition to hide the tab.
    static var openClawTabEnabled: Bool {
        #if HIDE_OPENCLAW_TAB
        false
        #else
        true
        #endif
    }
}
