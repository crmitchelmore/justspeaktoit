import CMigrationArchive
import Foundation
import SpeakCore

private final class MigrationZipDestination {
    let file: FileHandle
    let limit: UInt64
    var failure: Error?

    init(file: FileHandle, limit: UInt64) {
        self.file = file
        self.limit = limit
    }
}

private final class MigrationZipSource {
    let file: FileHandle
    let hasher: LocalModelSHA256Hasher
    var size: UInt64 = 0
    var count: UInt64 = 0
    var failure: Error?

    init(file: FileHandle, hasher: LocalModelSHA256Hasher) {
        self.file = file
        self.hasher = hasher
    }
}

final class DesktopMigrationZipWriter {
    private let destination: MigrationZipDestination
    private let writer: OpaquePointer
    private var budget = DataMigrationArchivePolicy.EntryBudget()
    private var finalized = false

    init(file: FileHandle, indexMemoryBudget: Int = 128 << 20, maximumEntries: UInt32 = 100_000) throws {
        guard indexMemoryBudget > 0, maximumEntries > 0 else {
            throw DataMigrationError.invalid("Invalid ZIP export budget.")
        }
        // Each stored entry has two bounded ZIP names plus fixed ZIP64 headers.
        let overhead = UInt64(DataMigrationArchivePolicy.maximumEntries) * (2 * UInt64(UInt16.max) + 256)
        let destination = MigrationZipDestination(
            file: file, limit: DataMigrationArchivePolicy.maximumArchiveBytes + overhead
        )
        var error = [CChar](repeating: 0, count: 512)
        guard let opened = jsti_zip_writer_open(
            Self.write, Unmanaged.passUnretained(destination).toOpaque(), indexMemoryBudget,
            maximumEntries, &error, error.count
        ) else {
            if let failure = destination.failure { throw failure }
            throw DataMigrationError.invalid("Cannot create the ZIP export: \(String(cString: error))")
        }
        self.destination = destination
        writer = opened
    }

    deinit { jsti_zip_writer_close(writer) }

    func add(_ data: Data, path: String) throws {
        guard UInt64(data.count) <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw DataMigrationError.invalid("An export category exceeds the JSON size limit.")
        }
        try admit(path: path, bytes: UInt64(data.count))
        let result = data.withUnsafeBytes {
            jsti_zip_writer_add_memory(writer, path, $0.baseAddress, $0.count)
        }
        try check(result)
    }

    func add(_ file: URL, path: String, digest: String, digests: LocalModelDigestProvider) throws {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false else {
            throw DataMigrationError.invalid("An export recording is not a regular non-linked file.")
        }
        let hasher = try digests.makeSHA256()
        let handle = try FileHandle(forReadingFrom: file)
        let source = MigrationZipSource(file: handle, hasher: hasher)
        do {
            source.size = try handle.seekToEnd()
            try admit(path: path, bytes: source.size)
            let result = jsti_zip_writer_add_file(
                writer, path, source.size, Self.read, Unmanaged.passUnretained(source).toOpaque()
            )
            if let failure = source.failure { throw failure }
            try check(result)
            guard source.count == source.size, try hasher.finish() == digest else {
                throw DataMigrationError.invalid("An export recording changed or its checksum does not match.")
            }
            try Task.checkCancellation()
        } catch {
            let original = error
            do { try handle.close() } catch {
                throw DataMigrationError.invalid(
                    "\(original.localizedDescription) The export recording could not be closed: "
                        + error.localizedDescription
                )
            }
            throw original
        }
        try handle.close()
    }

    func finish() throws {
        try Task.checkCancellation()
        guard !finalized else { throw DataMigrationError.invalid("The ZIP export is already finalized.") }
        try check(jsti_zip_writer_finalize(writer))
        finalized = true
    }

    private func admit(path: String, bytes: UInt64) throws {
        try Task.checkCancellation()
        guard !finalized, !path.isEmpty, !path.contains("\0"), path.utf8.count <= Int(UInt16.max) else {
            throw DataMigrationError.invalid("Invalid ZIP export entry.")
        }
        try budget.admit(.init(path: path, uncompressedBytes: bytes))
    }

    private func check(_ result: Int32) throws {
        if let failure = destination.failure { throw failure }
        guard result != 0 else {
            throw DataMigrationError.invalid(
                "Cannot write the ZIP export: \(String(cString: jsti_zip_writer_error(writer)))"
            )
        }
    }

    private static let write: jsti_zip_consume = { opaque, offset, buffer, count in
        guard let opaque, let buffer else { return 0 }
        let destination = Unmanaged<MigrationZipDestination>.fromOpaque(opaque).takeUnretainedValue()
        do {
            try Task.checkCancellation()
            guard offset <= destination.limit, UInt64(count) <= destination.limit - offset else {
                throw DataMigrationError.invalid("The ZIP export exceeds its output budget.")
            }
            try destination.file.seek(toOffset: offset)
            try destination.file.write(contentsOf: Data(bytes: buffer, count: count))
            return count
        } catch {
            destination.failure = error
            return 0
        }
    }

    private static let read: jsti_zip_read = { opaque, offset, buffer, count in
        guard let opaque, let buffer else { return 0 }
        let source = Unmanaged<MigrationZipSource>.fromOpaque(opaque).takeUnretainedValue()
        do {
            try Task.checkCancellation()
            guard offset == source.count, offset <= source.size else {
                throw DataMigrationError.invalid("Invalid export recording read offset.")
            }
            try source.file.seek(toOffset: offset)
            let bytes = try source.file.read(upToCount: Int(min(UInt64(count), source.size - offset))) ?? Data()
            try bytes.withUnsafeBytes {
                try source.hasher.update($0)
                if let address = $0.baseAddress { buffer.copyMemory(from: address, byteCount: $0.count) }
            }
            source.count += UInt64(bytes.count)
            return bytes.count
        } catch {
            source.failure = error
            return 0
        }
    }
}
