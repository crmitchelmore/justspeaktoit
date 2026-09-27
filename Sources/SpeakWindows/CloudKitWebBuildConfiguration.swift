/// CloudKit Web Services settings fixed when this app is built.
///
/// Committed without a token: such a build reports that iCloud sync is not
/// available and everything else works. A release build writes the container's
/// API token (the `CLOUDKIT_WEB_API_TOKEN` CI secret) into this file with
/// `scripts/windows-cloudkit/configure-cloudkit-web.py` before compiling. The
/// token is never committed. `signInCallback` is `loopback` or `custom-scheme`
/// (`CLOUDKIT_WEB_SIGN_IN_CALLBACK`) and must match the callback registered on
/// that token. See `Docs/windows-development.md`.
enum CloudKitWebBuildConfiguration {
    static let apiToken: String? = nil
    static let environment = "production"
    static let signInCallback = "loopback"
}
