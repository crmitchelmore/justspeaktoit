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
        Self.resolve()
    }

    /// `speak` is a plain executable, so `Bundle.main` describes the binary rather
    /// than the app that contains it. When the binary is the one embedded at
    /// `JustSpeakToIt.app/Contents/MacOS/speak`, walk up to that bundle and read
    /// its version; otherwise this is an unpackaged development build.
    static func resolve(
        executableURL: URL? = Bundle.main.executableURL,
        bundleLoader: (URL) -> Bundle? = Bundle.init(url:)
    ) -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        guard let executableURL else { return self.fallback }
        let appURL = executableURL
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // <name>.app
        guard appURL.pathExtension == "app",
              let bundle = bundleLoader(appURL),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return self.fallback
        }
        return version
    }
}
