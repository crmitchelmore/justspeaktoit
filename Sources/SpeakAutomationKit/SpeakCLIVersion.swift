import Foundation

/// Version reported by `speak --version` and by the MCP `serverInfo`.
///
/// Resolved from the enclosing app bundle when the CLI runs from inside
/// `JustSpeakToIt.app`, so the shipped binary can never disagree with the app it
/// talks to. Homebrew links the same embedded binary, so the fallback only
/// applies to unpackaged development builds.
public enum SpeakCLIVersion {
    static let fallback = "0.0.0-dev"

    public static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? self.fallback
    }
}
