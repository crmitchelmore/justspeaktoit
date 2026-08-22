import Foundation

/// Chooses which Sparkle feed a running build follows (issue #774).
///
/// Every build ships the legacy feed (`appcast.xml`, which offers the
/// universal DMG any Mac can run) in its Info.plist — including installs that
/// predate per-architecture downloads. A process running natively on Apple
/// Silicon switches to the arm64 feed; an Intel Mac, or a universal build
/// translated by Rosetta, stays on the universal feed, so an arm64-only update
/// is never offered where it could not run. Any other configured feed (a test
/// feed, for instance) is left untouched.
enum UpdateFeedSelection {
    static let legacyFeedURL = "https://justspeaktoit.com/appcast.xml"
    static let appleSiliconFeedURL = "https://justspeaktoit.com/appcast-arm64.xml"

    static func feedURL(
        configuredFeedURL: String?,
        machineArchitecture: String,
        isTranslated: Bool
    ) -> String? {
        guard configuredFeedURL == legacyFeedURL else { return configuredFeedURL }
        guard machineArchitecture == "arm64", !isTranslated else { return legacyFeedURL }
        return appleSiliconFeedURL
    }

    /// The feed for this process, derived from the bundle's `SUFeedURL`.
    static var current: String? {
        feedURL(
            configuredFeedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            machineArchitecture: machineArchitecture,
            isTranslated: isRunningUnderRosetta
        )
    }

    /// The CPU architecture this process runs as (`arm64` or `x86_64`).
    static var machineArchitecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let bytes = Array(buffer.prefix { $0 != 0 })
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }

    /// Whether this process is an x86_64 binary translated by Rosetta on an
    /// Apple Silicon Mac.
    static var isRunningUnderRosetta: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 else { return false }
        return translated == 1
    }
}
