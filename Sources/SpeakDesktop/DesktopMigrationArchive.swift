import Foundation
import SpeakCore

/// Archive names never become filesystem destinations. Only declared audio is
/// streamed to new app-owned files, with CRC and platform SHA-256 verification.
public enum DesktopMigrationArchive {
    public static func read(
        _ source: URL, digests: LocalModelDigestProvider,
        stagingRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> DataMigrationSnapshot {
        try Task.checkCancellation()
        let reader = try DesktopMigrationZipReader(source: source)
        guard let entry = reader.entry(named: "manifest.json") else {
            throw DataMigrationError.invalid("No migration manifest found.")
        }
        let manifest = try decoder.decode(DataMigrationManifest.self, from: reader.json(entry))
        try DataMigrationArchivePolicy.validateManifest(manifest)
        let total = reader.entries.reduce(UInt64(0)) { $0 + $1.bytes }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: stagingRoot.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value
        try DataMigrationArchivePolicy.requireStagingCapacity(archiveBytes: total, availableBytes: available)
        let directory = stagingRoot.appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        #if os(Windows)
        let permissions: [FileAttributeKey: Any] = [:]
        #else
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #endif
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: permissions
        )
        do {
            var snapshot = DataMigrationSnapshot(manifest: manifest, records: [:], directory: directory)
            for category in manifest.categories {
                try read(category, reader: reader, digests: digests, snapshot: &snapshot, directory: directory)
            }
            try Task.checkCancellation()
            return snapshot
        } catch {
            let original = error
            do { try FileManager.default.removeItem(at: directory) } catch {
                throw DataMigrationError.invalid(
                    "\(original.localizedDescription) The private migration staging could not be removed: "
                        + error.localizedDescription
                )
            }
            throw original
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func read(
        _ category: DataMigrationCategory, reader: DesktopMigrationZipReader,
        digests: LocalModelDigestProvider, snapshot: inout DataMigrationSnapshot, directory: URL
    ) throws {
        let values: [AnyCodable]
        do {
            guard let entry = reader.entry(named: category.rawValue + ".json") else {
                throw DataMigrationError.invalid("Category file missing.")
            }
            values = try decoder.decode([AnyCodable].self, from: reader.json(entry))
        } catch {
            try Task.checkCancellation()
            snapshot.notices.append("\(category.title): category could not be read; existing data will be preserved.")
            return
        }
        snapshot.records[category] = []
        var seen = Set<String>()
        for (index, value) in values.enumerated() {
            try Task.checkCancellation()
            do {
                let record = try decoder.decode(DataMigrationRecord.self, from: JSONEncoder().encode(value))
                guard seen.insert(record.identity).inserted else {
                    throw DataMigrationError.invalid("Duplicate entry identifier.")
                }
                if category == .recordings {
                    try extract(record, reader: reader, digests: digests, snapshot: &snapshot, directory: directory)
                }
                snapshot.records[category, default: []].append(record)
            } catch let failure as DesktopMigrationStagingError {
                throw failure
            } catch let failure as LocalModelDigestError {
                throw failure
            } catch {
                try Task.checkCancellation()
                snapshot.notices.append("\(category.title), item \(index + 1): skipped invalid item.")
            }
        }
    }

    private static func extract(
        _ record: DataMigrationRecord, reader: DesktopMigrationZipReader,
        digests: LocalModelDigestProvider, snapshot: inout DataMigrationSnapshot, directory: URL
    ) throws {
        guard let path = record.file, DataMigrationArchivePolicy.safeAudioPath(path),
              snapshot.files[path] == nil, let entry = reader.entry(named: path) else {
            throw DataMigrationError.invalid("Recording missing, duplicated or unsupported.")
        }
        let target = directory.appendingPathComponent(UUID().uuidString + "." + (path as NSString).pathExtension)
        try Data().write(to: target, options: .withoutOverwriting)
        do {
            let file = try FileHandle(forWritingTo: target)
            do {
                try reader.extract(entry, limit: DataMigrationArchivePolicy.maximumEntryBytes) {
                    try file.write(contentsOf: $0)
                }
                try file.close()
            } catch {
                let original = error
                try file.close()
                throw original
            }
            guard try digests.sha256(ofFileAt: target) == record.digest else {
                throw DataMigrationError.invalid("Recording checksum mismatch.")
            }
            snapshot.files[path] = target
        } catch {
            let original = error
            do { try FileManager.default.removeItem(at: target) } catch {
                throw DesktopMigrationStagingError(
                    detail: "\(original.localizedDescription) Partial migration audio could not be removed: "
                        + error.localizedDescription
                )
            }
            throw original
        }
    }
}

private struct DesktopMigrationStagingError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
