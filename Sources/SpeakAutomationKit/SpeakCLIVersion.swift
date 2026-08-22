import Foundation
import MachO

/// Version reported by `speak --version` and by the MCP `serverInfo`.
///
/// Resolution order:
/// 1. A version the release build linked into the executable itself (a
///    `__TEXT,__speak_ver` section), so a standalone CLI installed under
///    Application Support or by Homebrew describes itself without any bundle
///    around it (issue #775).
/// 2. The enclosing `JustSpeakToIt.app` bundle, for the CLI embedded at
///    `Contents/MacOS/speak`, so it can never disagree with the app it talks to.
/// 3. A development fallback for unpackaged builds.
public enum SpeakCLIVersion {
    static let fallback = "0.0.0-dev"
    /// Section the release build creates with `-sectcreate __TEXT __speak_ver <file>`.
    public static let embeddedSectionSegment = "__TEXT"
    public static let embeddedSectionName = "__speak_ver"

    public static var current: String {
        Self.resolve()
    }

    static func resolve(
        embeddedVersion: () -> Data? = Self.embeddedVersionData,
        mainBundleVersion: () -> String? = Self.mainBundleVersion,
        executableURL: URL? = Bundle.main.executableURL,
        bundleLoader: (URL) -> Bundle? = Bundle.init(url:)
    ) -> String {
        if let embedded = embeddedVersion().flatMap(Self.parseEmbeddedVersion) {
            return embedded
        }
        if let version = mainBundleVersion(), !version.isEmpty {
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

    /// The version of the bundle this process runs from, when it has one.
    static func mainBundleVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The linked section's bytes are a version string, possibly padded with
    /// whitespace or NUL bytes; anything else is ignored.
    static func parseEmbeddedVersion(_ data: Data) -> String? {
        let trimmed = data.prefix { $0 != 0 }
        guard let text = String(data: Data(trimmed), encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.count <= 64,
              version.allSatisfy({ $0.isLetter || $0.isNumber || ".-+".contains($0) })
        else { return nil }
        return version
    }

    /// Reads `__TEXT,__speak_ver` from the main executable image, if present.
    static func embeddedVersionData() -> Data? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        guard let bytes = header.withMemoryRebound(to: mach_header_64.self, capacity: 1, { header64 in
            getsectiondata(header64, embeddedSectionSegment, embeddedSectionName, &size)
        }), size > 0 else { return nil }
        return Data(bytes: bytes, count: Int(size))
    }
}
