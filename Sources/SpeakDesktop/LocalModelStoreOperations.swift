import Foundation
import SpeakCore

/// The blocking steps of installation. Every method runs on a dedicated
/// thread, never on the UI thread or the Swift concurrency pool.
///
/// Layout below `root/<package>/`: immutable `r-xxxxxxxx` version
/// directories, the atomically replaced `active.json` pointer, and
/// task-owned `staging-*` / `download-*` items that recovery removes.
struct LocalModelStoreOperations: Sendable {
    let root: URL
    let fileSystem: LocalModelFileSystem
    let digests: LocalModelDigestProvider
    let decompressor: LocalModelArchiveDecompressor
    /// Test seam: runs after a replacement is complete, immediately before
    /// its commit point is claimed.
    var beforePromotion: (@Sendable () -> Void)?

    private struct Pointer: Codable {
        let schemaVersion: Int
        let version: String
    }

    /// What the durable pointer says, independent of any cached state.
    enum DurablePointer: Equatable {
        case absent
        case version(String)
        case unreadable
    }

    func durablePointer(_ package: LocalModelPackage) -> DurablePointer {
        let pointerURL = packageDirectory(package).appendingPathComponent("active.json")
        guard fileSystem.itemKind(pointerURL) != .missing else { return .absent }
        guard let data = try? fileSystem.readSmallFile(pointerURL, maximumBytes: 4_096),
              let pointer = try? Self.decoder.decode(Pointer.self, from: data),
              pointer.schemaVersion == 1, Self.isVersionName(pointer.version) else { return .unreadable }
        return .version(pointer.version)
    }

    func packageDirectory(_ package: LocalModelPackage) -> URL {
        root.appendingPathComponent(package.identifier, isDirectory: true)
    }

    func preparePackageDirectory(_ package: LocalModelPackage) throws -> URL {
        try fileSystem.preparePrivateDirectory(root)
        let directory = packageDirectory(package)
        try fileSystem.preparePrivateDirectory(directory)
        return directory
    }

    /// The active installation, validated against the package pins and the
    /// installed file sizes, or nil when nothing is installed.
    func activeInstallation(_ package: LocalModelPackage) throws -> LocalModelInstallation? {
        let directory = packageDirectory(package)
        guard fileSystem.itemKind(directory) == .directory else { return nil }
        let version: String
        switch durablePointer(package) {
        case .absent: return nil
        case .unreadable: throw LocalModelStoreError.corruptRecord
        case .version(let active): version = active
        }
        let versionURL = directory.appendingPathComponent(version, isDirectory: true)
        let receiptData = try fileSystem.readSmallFile(
            versionURL.appendingPathComponent("receipt.json"), maximumBytes: 65_536
        )
        let receipt = try Self.decoder.decode(LocalModelInstallReceipt.self, from: receiptData)
        guard receipt.version == version, receipt.matches(package) else { throw LocalModelStoreError.corruptRecord }
        for file in package.installedFiles
        where fileSystem.itemKind(versionURL.appendingPathComponent(file.filename)) != .regularFile(file.byteCount) {
            throw LocalModelStoreError.corruptRecord
        }
        return LocalModelInstallation(package: package, directory: versionURL, receipt: receipt)
    }

    func newDownloadURL(_ package: LocalModelPackage) -> URL {
        packageDirectory(package).appendingPathComponent("download-\(UUID().uuidString).part")
    }

    /// Verifies the archive's exact bytes through one held reader, then
    /// expands it from that same reader and promotes the result.
    func installArchive(
        at archiveURL: URL, package: LocalModelPackage, origin: LocalModelInstallReceipt.Origin,
        cancellation: LocalModelCancellation, progress: @escaping (LocalModelInstallState) -> Void
    ) throws -> LocalModelInstallation {
        let reader = try fileSystem.openForReading(archiveURL)
        defer { reader.close() }
        guard reader.byteCount == package.archive.byteCount else { throw LocalModelStoreError.wrongArchive }
        progress(.verifying)
        let hasher = try digests.makeSHA256()
        while let chunk = try reader.read(maximum: LocalModelArchiveExtractor.chunkSize) {
            try cancellation.check()
            try chunk.withUnsafeBytes { try hasher.update($0) }
        }
        guard try hasher.finish() == package.archive.sha256 else { throw LocalModelStoreError.wrongArchive }
        try reader.rewind()
        return try stageAndPromote(package, origin: origin, cancellation: cancellation) { staging in
            let extractor = LocalModelArchiveExtractor(
                archive: package.archive, installedFiles: package.installedFiles, fileSystem: fileSystem,
                digests: digests, decompressor: decompressor
            )
            _ = try extractor.extract(from: reader, into: staging, cancellation: cancellation) { consumed in
                progress(.expanding(processed: consumed, total: package.archive.byteCount))
            }
        }
    }

    /// Copies the pinned files from an extracted folder, verifying each.
    func installFolder(
        at folderURL: URL, package: LocalModelPackage, cancellation: LocalModelCancellation
    ) throws -> LocalModelInstallation {
        guard package.allowsFolderImport else { throw LocalModelStoreError.folderImportUnsupported }
        let source = try LocalModelFolderImport(fileSystem: fileSystem, package: package).sourceDirectory(folderURL)
        return try stageAndPromote(package, origin: .folderImport, cancellation: cancellation) { staging in
            for file in package.installedFiles {
                try copyVerified(file, from: source.appendingPathComponent(file.filename),
                                 to: staging.appendingPathComponent(file.filename), cancellation: cancellation)
            }
        }
    }

    private func copyVerified(
        _ file: LocalModelPinnedFile, from source: URL, to destination: URL, cancellation: LocalModelCancellation
    ) throws {
        let reader = try fileSystem.openForReading(source)
        defer { reader.close() }
        guard reader.byteCount == file.byteCount else { throw LocalModelStoreError.wrongModel(file.filename) }
        let writer = try fileSystem.createFile(destination)
        do {
            let hasher = try digests.makeSHA256()
            while let chunk = try reader.read(maximum: LocalModelArchiveExtractor.chunkSize) {
                try cancellation.check()
                try chunk.withUnsafeBytes { bytes in
                    try hasher.update(bytes)
                    try writer.write(bytes)
                }
            }
            guard try hasher.finish() == file.sha256 else { throw LocalModelStoreError.wrongModel(file.filename) }
            try writer.commit()
        } catch {
            writer.discard()
            throw error
        }
    }

    /// Fills a private staging directory, then promotes it only if this
    /// operation claims its commit point before cancellation. Promotion is
    /// a rename of the complete directory followed by an atomic pointer
    /// replacement, so the previous version stays active until then.
    private func stageAndPromote(
        _ package: LocalModelPackage, origin: LocalModelInstallReceipt.Origin,
        cancellation: LocalModelCancellation, fill: (URL) throws -> Void
    ) throws -> LocalModelInstallation {
        let directory = try preparePackageDirectory(package)
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fileSystem.preparePrivateDirectory(staging)
        do {
            try cancellation.check()
            try fill(staging)
            let version = String(format: "r-%08x", UInt32.random(in: .min ... .max))
            let receipt = LocalModelInstallReceipt(
                schemaVersion: 1, packageIdentifier: package.identifier, version: version, origin: origin,
                sourceURL: package.archive.url.absoluteString, archiveByteCount: package.archive.byteCount,
                archiveSHA256: package.archive.sha256, digestProvider: digests.name, installedAt: Date(),
                files: package.installedFiles.map { .init(name: $0.filename, byteCount: $0.byteCount, sha256: $0.sha256) }
            )
            try fileSystem.writeNewFile(staging.appendingPathComponent("NOTICE.txt"), data: Data(package.notice.utf8))
            try fileSystem.writeNewFile(staging.appendingPathComponent("receipt.json"), data: Self.encoder.encode(receipt))
            beforePromotion?()
            guard cancellation.claimCommit() else { throw CancellationError() }
            let versionURL = directory.appendingPathComponent(version, isDirectory: true)
            try fileSystem.moveItem(from: staging, to: versionURL)
            let pointer = try Self.encoder.encode(Pointer(schemaVersion: 1, version: version))
            try fileSystem.replaceFile(directory.appendingPathComponent("active.json"), with: pointer)
            return LocalModelInstallation(package: package, directory: versionURL, receipt: receipt)
        } catch {
            try? fileSystem.removeTree(staging, within: directory)
            throw error
        }
    }

    /// Removes task-owned leftovers and every version that is neither leased
    /// (`keeping`) nor named by the durable pointer. The pointer is read
    /// here, never taken from a cache, so a store that has not yet
    /// discovered a persisted installation cannot delete it; an unreadable
    /// pointer keeps every version. Callers hold the package's operation
    /// reservation, so no other work owns a staging or download item.
    func removeUnreferenced(_ package: LocalModelPackage, keeping: Set<String>) throws {
        let directory = packageDirectory(package)
        guard fileSystem.itemKind(directory) == .directory else { return }
        let pointer = durablePointer(package)
        for name in try fileSystem.contentsOfDirectory(directory) {
            let isLeftover = name.hasPrefix("staging-") || name.hasPrefix("download-") || name.hasPrefix(".replace-")
            let isRetired = Self.isVersionName(name) && !keeping.contains(name)
                && pointer != .unreadable && pointer != .version(name)
            guard isLeftover || isRetired else { continue }
            try fileSystem.removeTree(directory.appendingPathComponent(name), within: directory)
        }
    }

    /// Removes the pointer first, so a partial deletion reads as uninstalled.
    func uninstall(_ package: LocalModelPackage, keeping: Set<String>) throws {
        let directory = packageDirectory(package)
        guard fileSystem.itemKind(directory) == .directory else { return }
        let pointer = directory.appendingPathComponent("active.json")
        if fileSystem.itemKind(pointer) != .missing { try fileSystem.removeTree(pointer, within: directory) }
        try removeUnreferenced(package, keeping: keeping)
    }

    static func isVersionName(_ name: String) -> Bool {
        name.utf8.count == 10 && name.hasPrefix("r-")
            && name.utf8.dropFirst(2).allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
