import Foundation
import SpeakCore
#if os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Immutable, separately owned retention. No update, delete or effective-settings route exists.
public struct DesktopNativeRetainedCapsule: Sendable {
    public static let directoryPrefix = "native-retained-"
    public static let filename = "records.json"
    public let directory: URL
    private let sealedBytes: Data
    private let readReceipt: DesktopOwnedAppDataFileReader.StrictReceipt

    public static func create(
        _ archive: DesktopNativeConfigurationArchive, in root: URL,
        identifier: UUID = UUID(), storage: DesktopMigrationArchive.Storage? = nil,
        publication: DesktopFilePublication.Copy,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Self {
        let bytes = try DesktopNativeConfigurationArchiveCodec.encode(archive, checkCancellation: checkCancellation)
        _ = try DesktopNativeConfigurationArchiveCodec.decode(bytes, checkCancellation: checkCancellation)
        try DesktopMigrationStaging.requireLocalFile(root)
        let operations = try DesktopMigrationArchive.Storage.resolve(storage)
        let directory = root.appendingPathComponent(directoryPrefix + identifier.uuidString, isDirectory: true)
        try checkCancellation()
        // Exclusive creation, not a UUID-shaped name, establishes this invocation's cleanup ownership.
        try operations.createDirectory(directory)
        let staging = directory.appendingPathComponent("unpublished.json")
        let destination = directory.appendingPathComponent(filename)
        var published = false
        do {
            try operations.createFile(staging)
            try write(bytes, to: staging, checkCancellation: checkCancellation)
            _ = try readValidated(
                in: directory, filename: "unpublished.json", expectedBytes: bytes, checkCancellation: checkCancellation
            )
            try checkCancellation()
            do {
                try DesktopFilePublication.copy(source: staging, destination: destination, using: publication)
                published = true
            } catch let error as DesktopFilePublication.CopyCompletionFailure {
                published = true
                throw error
            } catch let error as DesktopFilePublicationCleanupFailure {
                published = true
                throw error
            }
            try DesktopNativeRetentionIO.removeStaging(staging)
            let validated = try readValidated(
                in: directory, expectedBytes: bytes, checkCancellation: checkCancellation
            )
            return Self(directory: directory, sealedBytes: bytes, readReceipt: validated.receipt)
        } catch let primary {
            if published || FileManager.default.fileExists(atPath: destination.path) {
                throw DesktopNativeRetentionPublishedFailure(directory: directory, underlyingError: primary)
            }
            do {
                try cleanupUnpublished(staging: staging, directory: directory)
            } catch {
                throw DesktopNativeRetentionCleanupFailure(primaryError: primary, cleanupError: error)
            }
            throw primary
        }
    }

    /// Original byte and strict read receipts detect change; neither supplies mutation CAS.
    public func reload(
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationArchive {
        let validated = try Self.readValidated(
            in: directory, expectedBytes: sealedBytes, checkCancellation: checkCancellation
        )
        try DesktopOwnedAppDataFileReader.revalidateStrict(readReceipt, checkCancellation: checkCancellation)
        return validated.archive
    }

    /// Restart inspection is read-only. A directory name alone is never ownership or write authority.
    public static func read(
        from directory: URL, checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationArchive {
        let directory = try DesktopMigrationStaging.directory(directory, prefix: directoryPrefix)
        return try readValidated(in: directory, checkCancellation: checkCancellation).archive
    }

    public func exportProjection(
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DataMigrationSnapshot {
        let archive = try reload(checkCancellation: checkCancellation)
        return .init(
            manifest: .init(categories: [.settings], scopes: ["settings": archive.coverage.selectionScope]),
            records: [.settings: archive.records]
        )
    }

    private static func write(_ bytes: Data, to file: URL, checkCancellation: () throws -> Void) throws {
        let handle = try FileHandle(forWritingTo: file)
        try DesktopNativeRetentionIO.perform(closing: { try handle.close() }, operation: {
            var offset = 0
            while offset < bytes.count {
                try checkCancellation()
                let end = min(offset + 65_536, bytes.count)
                try handle.write(contentsOf: bytes.subdata(in: offset..<end))
                offset = end
            }
            try handle.synchronize()
        })
    }

    private static func readValidated(
        in directory: URL, filename: String = Self.filename, expectedBytes: Data? = nil,
        checkCancellation: () throws -> Void
    ) throws -> (archive: DesktopNativeConfigurationArchive, receipt: DesktopOwnedAppDataFileReader.StrictReceipt) {
        let snapshot = try DesktopOwnedAppDataFileReader.readStrict(
            filename, appDirectory: directory,
            maximumBytes: DesktopNativeConfigurationArchiveCodec.maximumEncodedBytes,
            checkCancellation: checkCancellation
        )
        guard let bytes = snapshot.data else { throw CocoaError(.fileReadNoSuchFile) }
        if let expectedBytes, bytes != expectedBytes { throw invalid("The immutable retained capsule changed.") }
        let archive = try DesktopNativeConfigurationArchiveCodec.decode(bytes, checkCancellation: checkCancellation)
        try DesktopOwnedAppDataFileReader.revalidateStrict(snapshot.receipt, checkCancellation: checkCancellation)
        return (archive, snapshot.receipt)
    }

    private static func invalid(_ message: String) -> DataMigrationError { .invalid(message) }

    private static func cleanupUnpublished(staging: URL, directory: URL) throws {
        try DesktopNativeRetentionIO.removeStaging(staging, allowingMissing: true)
        #if os(Windows)
        let path = directory.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) }
        guard let path else { throw invalid("Invalid owned capsule cleanup path.") }
        let native = Array(path.utf16) + [0]
        let removed = native.withUnsafeBufferPointer { _wrmdir($0.baseAddress) == 0 }
        #else
        let removed = directory.path.withCString { rmdir($0) == 0 }
        #endif
        guard removed else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

/// Validated data may already be published; cleanup must never remove it or retry an overwrite.
public struct DesktopNativeRetentionPublishedFailure: LocalizedError, Sendable {
    public let directory: URL
    public let underlyingError: any Error
    public var errorDescription: String? {
        "The retained capsule may already be published, but completion could not be confirmed. "
            + "It was kept; no success or retry permission was reported."
    }
}
