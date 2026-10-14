import Foundation
import SpeakCore
import ZIPFoundation

/// Reads only declared JSON and audio entries into a private staging directory.
/// No archive path is ever used as a destination path on the receiving Mac.
enum MigrationArchive {
    static func write(_ snapshot: MigrationSnapshot, to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: destination, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("export.zip")
        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try add(MigrationCoding.encoder.encode(snapshot.manifest), path: "manifest.json", to: archive)
            for category in snapshot.manifest.categories {
                try add(MigrationCoding.encoder.encode(snapshot.records[category] ?? []),
                        path: category.rawValue + ".json", to: archive)
            }
            for (path, url) in snapshot.files.sorted(by: { $0.key < $1.key }) {
                guard safeAudioPath(path),
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                else {
                    throw MigrationError.invalid("A recording is unavailable or is not a regular file.")
                }
                try archive.addEntry(with: path, fileURL: url, compressionMethod: .none)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    static func read(_ source: URL) throws -> MigrationSnapshot {
        let archive = try Archive(url: source, accessMode: .read)
        try preflight(archive)
        guard let entry = archive["manifest.json"]
        else {
            throw MigrationError.invalid("No migration manifest found.")
        }
        let manifest = try MigrationCoding.decoder.decode(
            MigrationManifest.self,
            from: data(entry, in: archive)
        )
        try DataMigrationArchivePolicy.validateManifest(manifest)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var snapshot = MigrationSnapshot(manifest: manifest, records: [:], directory: directory)
        for category in manifest.categories {
            readCategory(category, archive: archive, directory: directory, snapshot: &snapshot)
        }
        return snapshot
    }

    private static func readCategory(_ category: MigrationCategory, archive: Archive, directory: URL,
                                     snapshot: inout MigrationSnapshot) {
        do {
            guard let entry = archive[category.rawValue + ".json"] else {
                throw MigrationError.invalid("Category file missing")
            }
            let values = try MigrationCoding.decoder.decode(
                [AnyCodable].self,
                from: data(entry, in: archive)
            )
            snapshot.records[category] = []
            var seen = Set<String>()
            for (index, value) in values.enumerated() {
                do {
                    let record = try MigrationCoding.decode(MigrationRecord.self, value)
                    guard seen.insert(record.identity).inserted else {
                        throw MigrationError.invalid("Duplicate entry identifier")
                    }
                    if category == .recordings {
                        try extractRecording(
                            record,
                            archive: archive,
                            directory: directory,
                            snapshot: &snapshot
                        )
                    }
                    snapshot.records[category, default: []].append(record)
                } catch {
                    snapshot.notices.append("\(category.title), item \(index + 1): skipped invalid item.")
                }
            }
        } catch {
            snapshot.notices
                .append("\(category.title): category could not be read; existing data will be preserved.")
        }
    }

    private static func extractRecording(_ record: MigrationRecord, archive: Archive, directory: URL,
                                         snapshot: inout MigrationSnapshot) throws {
        guard let path = record.file, safeAudioPath(path), let audio = archive[path],
              audio.type == .file, audio.uncompressedSize <= DataMigrationArchivePolicy.maximumEntryBytes else {
            throw MigrationError.invalid("Recording missing or unsupported")
        }
        guard snapshot.files[path] == nil else {
            throw MigrationError.invalid("Duplicate recording path")
        }
        let target = directory
            .appendingPathComponent(UUID().uuidString + "." + (path as NSString)
                .pathExtension)
        do {
            let checksum = try archive.extract(audio, to: target)
            guard checksum == audio.checksum,
                  try MigrationCoding.fileDigest(target) == record.digest else {
                throw MigrationError.invalid("Recording checksum mismatch")
            }
            snapshot.files[path] = target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    static func safeAudioPath(_ path: String) -> Bool {
        DataMigrationArchivePolicy.safeAudioPath(path)
    }

    private static func preflight(_ archive: Archive) throws {
        let bytes = try DataMigrationArchivePolicy.preflight(archive.lazy.map {
            DataMigrationArchivePolicy.Entry(path: $0.path, uncompressedBytes: $0.uncompressedSize)
        })
        let space = try FileManager.default.temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        try DataMigrationArchivePolicy.requireStagingCapacity(
            archiveBytes: bytes, availableBytes: space.map { UInt64(max(0, $0)) }
        )
    }

    private static func data(_ entry: Entry, in archive: Archive) throws -> Data {
        guard entry.type == .file, entry.uncompressedSize <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw MigrationError.invalid("Invalid or oversized category file")
        }
        var result = Data()
        let checksum = try archive.extract(entry) { chunk in
            guard UInt64(result.count) + UInt64(chunk.count) <= DataMigrationArchivePolicy.maximumJSONBytes else {
                throw MigrationError.invalid("Category exceeds size limit")
            }
            result.append(chunk)
        }
        guard checksum == entry.checksum else {
            throw MigrationError.invalid("Category checksum mismatch")
        }
        return result
    }

    private static func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { position, count in
            data.subdata(in: Int(position)..<(Int(position) + count))
        }
    }
}
