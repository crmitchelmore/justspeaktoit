import Foundation

@MainActor
final class MigrationAudioInstallation {
    let folder: URL
    private var created: [URL] = []

    init(folder: URL) { self.folder = folder }

    func checkSpace(records: [MigrationRecord], files: [String: URL]) throws {
        var bytes: Int64 = 64_000_000
        for record in records {
            guard let path = record.file, let source = files[path] else { continue }
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            bytes += Int64(size)
        }
        let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let available, bytes > available {
            throw MigrationError.invalid("There is not enough free space to install these recordings.")
        }
    }

    func install(source: URL, destination: URL, digest: String) async throws {
        let existed = FileManager.default.fileExists(atPath: destination.path)
        try await Task.detached {
            if existed, try MigrationCoding.fileDigest(destination) == digest { return }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            guard try MigrationCoding.fileDigest(temporary) == digest else {
                throw MigrationError.invalid("Recording changed during import.")
            }
            if existed {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        }.value
        if !existed { created.append(destination) }
    }

    func rollback() {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created.removeAll()
    }
}
