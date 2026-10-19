import Foundation

public struct DesktopAboutInformation: Equatable, Sendable {
    public enum Platform: String, Sendable {
        case windows = "Windows", linux = "Linux"
    }

    public let version: String?
    public let build: String?
    public let commit: String?
    public let configuration: String
    public let metadataNotice: String?

    public init(
        version: String? = nil, build: String? = nil, commit: String? = nil,
        configuration: String, metadataNotice: String? = nil
    ) {
        self.version = Self.displayToken(version)
        self.build = Self.displayToken(build)
        self.commit = Self.commitToken(commit)
        self.configuration = configuration == "release" ? "Release" : "Development"
        let invalidIdentity = (version != nil && self.version == nil)
            || (build != nil && self.build == nil) || (commit != nil && self.commit == nil)
        self.metadataNotice = metadataNotice ?? (invalidIdentity
            ? "Build identity contains invalid values. Re-extract the original app download." : nil)
    }

    public func details(for platform: Platform) -> String {
        var lines = [
            "Version: " + (version ?? "Unversioned developer preview"),
            "Build: " + (build ?? "Not stamped") + " (" + configuration + ")",
            "Commit: " + (commit.map { String($0.prefix(12)) } ?? "Not stamped"),
            "Distribution: " + platform.rawValue + " developer preview",
            "Updates are manual; this preview has no automatic updater.",
            "View Releases opens your browser. Check that a download supports " + platform.rawValue + "."
        ]
        if let metadataNotice { lines.append(metadataNotice) }
        return lines.joined(separator: "\n")
    }

    /// These files describe the installed executable, never the current checkout
    /// or a release feed. Their contents do not authorize downloads or installation.
    public static func current(
        executableURL: URL? = Bundle.main.executableURL,
        bundleInformation: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Self {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let version = bundleInformation["CFBundleShortVersionString"] as? String
        let build = bundleInformation["CFBundleVersion"] as? String
        let commit = bundleInformation["GitCommitSHA"] as? String
        guard let directory = executableURL?.deletingLastPathComponent() else {
            return Self(version: version, build: build, commit: commit, configuration: configuration)
        }
        for name in ["app-build-metadata.json", "bundle-manifest.json"] {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let metadata = try decodeMetadata(Data(contentsOf: file))
                return Self(
                    version: version, build: build, commit: commit ?? metadata.commit,
                    configuration: metadata.configuration ?? configuration
                )
            } catch {
                return Self(
                    version: version, build: build, commit: commit, configuration: configuration,
                    metadataNotice: "Build metadata could not be read. Re-extract the original app download."
                )
            }
        }
        return Self(version: version, build: build, commit: commit, configuration: configuration)
    }

    static func decodeMetadata(_ data: Data) throws -> (commit: String, configuration: String?) {
        struct Metadata: Decodable {
            let sourceCommit: String?
            let configuration: String?
            let application: Application?
            struct Application: Decodable {
                let sourceCommit: String?
                let configuration: String?
            }
        }
        guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard let commit = commitToken(metadata.sourceCommit ?? metadata.application?.sourceCommit) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let configuration = metadata.configuration ?? metadata.application?.configuration
        guard configuration == nil || configuration == "release" || configuration == "debug" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (commit, configuration)
    }

    private static func displayToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return value
    }

    private static func commitToken(_ value: String?) -> String? {
        guard let value, value.count == 40 || value.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return value
    }
}
