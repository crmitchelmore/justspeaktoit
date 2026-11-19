/// The public PostHog project key stamped into Windows and Linux release builds.
///
/// The Windows x64, Windows ARM64 and Linux Flatpak workflows run
/// `scripts/desktop-analytics/configure-posthog-key.py` before building, only
/// on `main` and release manifest tags, to fill this in from the
/// `POSTHOG_PROJECT_KEY` secret in that build's checkout. It is never
/// committed: development and pull-request builds keep `nil` and send nothing.
public enum DesktopAnalyticsBuildConfiguration {
    public static let postHogProjectKey: String? = nil
}
