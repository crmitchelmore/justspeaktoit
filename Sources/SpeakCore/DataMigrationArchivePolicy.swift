import Foundation

public enum DataMigrationArchivePolicy {
    public static let maximumEntries = 100_000
    public static let maximumEntryBytes: UInt64 = 20_000_000_000
    public static let maximumArchiveBytes: UInt64 = 50_000_000_000
    public static let maximumJSONBytes: UInt64 = 128_000_000
    public static let stagingReserveBytes: UInt64 = 64_000_000

    public struct Entry: Sendable {
        public let path: String
        public let uncompressedBytes: UInt64

        public init(path: String, uncompressedBytes: UInt64) {
            self.path = path
            self.uncompressedBytes = uncompressedBytes
        }
    }

    public static func preflight<S: Sequence>(_ entries: S) throws -> UInt64 where S.Element == Entry {
        var paths = Set<String>()
        var bytes: UInt64 = 0
        for entry in entries {
            guard paths.insert(entry.path).inserted, paths.count <= maximumEntries,
                  entry.uncompressedBytes <= maximumEntryBytes else {
                throw DataMigrationError.invalid("The archive contains duplicate paths or oversized entries.")
            }
            bytes += entry.uncompressedBytes
            guard bytes <= maximumArchiveBytes else {
                throw DataMigrationError.invalid("The archive exceeds 50 GB.")
            }
        }
        return bytes
    }

    public static func requireStagingCapacity(archiveBytes: UInt64, availableBytes: UInt64?) throws {
        guard let availableBytes else { return }
        let required = archiveBytes.addingReportingOverflow(stagingReserveBytes)
        guard !required.overflow, required.partialValue <= availableBytes else {
            throw DataMigrationError.invalid("There is not enough free space to read this export.")
        }
    }

    public static func validateManifest(_ manifest: DataMigrationManifest) throws {
        guard manifest.format == DataMigrationFormat.identifier, manifest.version == DataMigrationFormat.version,
              Set(manifest.categories).count == manifest.categories.count else {
            throw DataMigrationError.invalid("This export format is unsupported. Update the app before importing it.")
        }
    }

    public static func safeAudioPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // Version-1 archive acceptance is deliberately narrower than audio import.
        let extensions: Set<String> = ["wav", "m4a", "mp3", "flac", "ogg", "aiff", "aif", "aac", "caf", "audio"]
        return parts.count == 2 && parts[0] == "recordings" && !parts[1].isEmpty
            && extensions.contains((path as NSString).pathExtension.lowercased())
            && !path.contains("..") && !path.contains("\\") && !path.contains("\0")
    }
}
