/// CloudKit Web Services settings fixed when this app is built.
///
/// Committed without a token: such a build reports that iCloud sync is not
/// available and everything else works. A release build writes the container's
/// API token (the `CLOUDKIT_WEB_API_TOKEN` CI secret, the same one Windows
/// uses) into this file with `scripts/linux-cloudkit-configure.py` before
/// compiling. The token is never committed. See `Docs/linux-development.md`.
enum CloudKitWebBuildConfiguration {
    static let apiToken: String? = nil
    static let environment = "production"
}
