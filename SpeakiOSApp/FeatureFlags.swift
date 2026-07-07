import Foundation

/// Build-time feature flags for the iOS app.
///
/// Flags are resolved from Swift active compilation conditions so they can be
/// toggled per build without shipping a runtime setting. Generate the project
/// with the corresponding environment variable to flip a flag, e.g.:
///
///     SHOW_OPENCLAW_TAB=1 tuist generate
///
/// (see `Project.swift`, which maps the env var to the
/// `SHOW_OPENCLAW_TAB` compilation condition).
enum FeatureFlags {
    /// Whether the OpenClaw tab is shown in the main tab bar. Defaults to
    /// `false` (hidden) so App Store builds ship without it; set the
    /// `SHOW_OPENCLAW_TAB` build condition to bring the tab back (e.g. for
    /// internal testing).
    static var openClawTabEnabled: Bool {
        #if SHOW_OPENCLAW_TAB
        true
        #else
        false
        #endif
    }
}
