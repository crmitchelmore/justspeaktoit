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
            let reread = try readBytes(staging, checkCancellation: checkCancellation)
            guard reread == bytes else { throw invalid("Retained staging changed before publication.") }
            _ = try DesktopNativeConfigurationArchiveCodec.decode(reread, checkCancellation: checkCancellation)
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
            let capsule = Self(directory: directory, sealedBytes: bytes)
            _ = try capsule.reload(checkCancellation: checkCancellation)
            return capsule
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

    /// A held byte receipt detects changed content; it never supplies mutation CAS.
    public func reload(
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationArchive {
        let bytes = try Self.readBytes(directory.appendingPathComponent(Self.filename),
                                       checkCancellation: checkCancellation)
        guard bytes == sealedBytes else { throw Self.invalid("The immutable retained capsule changed.") }
        return try DesktopNativeConfigurationArchiveCodec.decode(bytes, checkCancellation: checkCancellation)
    }

    /// Restart inspection is read-only. A directory name alone is never ownership or write authority.
    public static func read(
        from directory: URL, checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationArchive {
        let directory = try DesktopMigrationStaging.directory(directory, prefix: directoryPrefix)
        let bytes = try readBytes(directory.appendingPathComponent(filename), checkCancellation: checkCancellation)
        return try DesktopNativeConfigurationArchiveCodec.decode(bytes, checkCancellation: checkCancellation)
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

    private static func readBytes(_ file: URL, checkCancellation: () throws -> Void) throws -> Data {
        try checkCancellation()
        try DesktopMigrationStaging.requireLocalFile(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw invalid("Retained native data must be a regular file.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        return try DesktopNativeRetentionIO.perform(closing: { try handle.close() }, operation: {
            var bytes = Data()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                try checkCancellation()
                guard UInt64(bytes.count) + UInt64(chunk.count)
                    <= DesktopNativeConfigurationArchiveCodec.maximumEncodedBytes else {
                    throw invalid("Retained native data exceeds the canonical archive budget.")
                }
                bytes.append(chunk)
            }
            return bytes
        })
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
