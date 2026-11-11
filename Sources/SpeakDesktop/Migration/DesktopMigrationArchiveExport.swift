import Foundation
import SpeakCore

extension DesktopMigrationArchive {
    /// Returns an owned private staging file. The host must explicitly publish
    /// it to the user's destination, then remove its containing directory.
    public static func export(
        _ snapshot: DataMigrationSnapshot, digests: LocalModelDigestProvider,
        stagingRoot: URL = FileManager.default.temporaryDirectory, includeCredentials: Bool = false,
        storage: Storage? = nil
    ) throws -> URL {
        try Task.checkCancellation()
        let storage = try Storage.resolve(storage)
        try DataMigrationArchivePolicy.validateManifest(snapshot.manifest)
        let audio = try exportAudio(snapshot, includeCredentials: includeCredentials)
        let directory = stagingRoot.appendingPathComponent("migration-export-\(UUID().uuidString)", isDirectory: true)
        try storage.createDirectory(directory)
        do {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent("export.zip")
            try storage.createFile(file)
            try writeExport(snapshot, audio: audio, file: file, digests: digests)
            try Task.checkCancellation()
            return file
        } catch {
            let original = error
            do { try FileManager.default.removeItem(at: directory) } catch {
                throw DataMigrationError.invalid(
                    "\(original.localizedDescription) The partial export could not be removed: "
                        + error.localizedDescription
                )
            }
            throw original
        }
    }

    private static func exportAudio(
        _ snapshot: DataMigrationSnapshot, includeCredentials: Bool
    ) throws -> [String: String] {
        guard includeCredentials || !snapshot.manifest.categories.contains(.credentials) else {
            throw DataMigrationError.invalid("Credential export requires explicit opt-in.")
        }
        for category in snapshot.manifest.categories {
            try Task.checkCancellation()
            let prefix = category.title
            guard snapshot.records[category] != nil,
                  !snapshot.notices.contains(where: { $0.hasPrefix(prefix + ":") || $0.hasPrefix(prefix + ",") }) else {
                throw DataMigrationError.invalid("A missing or damaged category cannot be exported as empty.")
            }
            for record in snapshot.records[category] ?? [] {
                let isCredential = record.kind == "secret"
                    || DataMigrationPreferenceCatalog.category(for: record.id) == .credentials
                guard !isCredential || category == .credentials else {
                    throw DataMigrationError.invalid("A credential has an invalid export category.")
                }
            }
        }
        var audio: [String: String] = [:]
        for record in snapshot.records[.recordings] ?? [] where snapshot.manifest.categories.contains(.recordings) {
            try Task.checkCancellation()
            guard let path = record.file, DataMigrationArchivePolicy.safeAudioPath(path), audio[path] == nil,
                  snapshot.files[path] != nil, let digest = record.digest,
                  digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw DataMigrationError.invalid("An export recording is missing, duplicated or has an invalid digest.")
            }
            audio[path] = digest
        }
        return audio
    }

    private static func writeExport(
        _ snapshot: DataMigrationSnapshot, audio: [String: String], file: URL, digests: LocalModelDigestProvider
    ) throws {
        let handle = try FileHandle(forWritingTo: file)
        do {
            let writer = try DesktopMigrationZipWriter(file: handle)
            try writer.add(DataMigrationCoding.encoder.encode(snapshot.manifest), path: "manifest.json")
            for category in snapshot.manifest.categories {
                try Task.checkCancellation()
                let records = snapshot.records[category] ?? []
                try writer.add(DataMigrationCoding.encoder.encode(records), path: category.rawValue + ".json")
            }
            for (path, digest) in audio.sorted(by: { $0.key < $1.key }) {
                guard let source = snapshot.files[path] else {
                    throw DataMigrationError.invalid("An export recording disappeared from its snapshot.")
                }
                try writer.add(source, path: path, digest: digest, digests: digests)
            }
            try writer.finish()
            try handle.synchronize()
        } catch {
            let original = error
            do { try handle.close() } catch {
                throw DataMigrationError.invalid(
                    "\(original.localizedDescription) The partial export could not be closed: "
                        + error.localizedDescription
                )
            }
            throw original
        }
        try handle.close()
    }
}
