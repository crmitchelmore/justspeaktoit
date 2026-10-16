import CMigrationArchive
import Foundation
import SpeakCore

final class DesktopMigrationZipInput {
    let file: FileHandle
    var failure: Error?

    init(_ source: URL) throws {
        file = try FileHandle(forReadingFrom: source)
    }

    deinit { try? file.close() }
}

final class DesktopMigrationZipOutput {
    let limit: UInt64
    let consume: (Data) throws -> Void
    var count: UInt64 = 0
    var failure: Error?

    init(limit: UInt64, consume: @escaping (Data) throws -> Void) {
        self.limit = limit
        self.consume = consume
    }
}

final class DesktopMigrationZipReader {
    struct Entry {
        let index: UInt32
        let path: String
        let bytes: UInt64
        let regular: Bool
    }

    private let input: DesktopMigrationZipInput
    private let reader: OpaquePointer
    let entries: [Entry]
    private let entriesByPath: [String: Entry]

    init(source: URL, indexMemoryBudget: Int = 128 << 20) throws {
        guard indexMemoryBudget > 0 else { throw DataMigrationError.invalid("Invalid ZIP index memory budget.") }
        let input = try DesktopMigrationZipInput(source)
        let size = try input.file.seekToEnd()
        var error = [CChar](repeating: 0, count: 512)
        let opened = jsti_zip_open(
            size, Self.read, Unmanaged.passUnretained(input).toOpaque(), indexMemoryBudget,
            UInt32(DataMigrationArchivePolicy.maximumEntries), &error, error.count
        )
        guard let opened else {
            if let failure = input.failure { throw failure }
            throw DataMigrationError.invalid("Cannot read the ZIP archive: \(String(cString: error))")
        }
        do {
            entries = try Self.list(opened)
        } catch {
            jsti_zip_close(opened)
            throw error
        }
        self.input = input
        reader = opened
        entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    }

    deinit { jsti_zip_close(reader) }

    func entry(named path: String) -> Entry? { entriesByPath[path] }

    func extract(_ entry: Entry, limit: UInt64, consume: @escaping (Data) throws -> Void) throws {
        try Task.checkCancellation()
        guard entry.regular, entry.bytes <= limit else {
            throw DataMigrationError.invalid("Invalid or oversized archive entry.")
        }
        let output = DesktopMigrationZipOutput(limit: limit, consume: consume)
        let succeeded = jsti_zip_extract(reader, entry.index, Self.write, Unmanaged.passUnretained(output).toOpaque())
        if let failure = output.failure { throw failure }
        if let failure = input.failure { throw failure }
        guard succeeded != 0, output.count == entry.bytes else {
            throw DataMigrationError.invalid("Cannot extract the ZIP entry: \(String(cString: jsti_zip_error(reader)))")
        }
    }

    func json(_ entry: Entry) throws -> Data {
        let output = NSMutableData()
        try extract(entry, limit: DataMigrationArchivePolicy.maximumJSONBytes) { output.append($0) }
        return output as Data
    }

    private static func list(_ reader: OpaquePointer) throws -> [Entry] {
        var entries: [Entry] = []
        for index in 0..<jsti_zip_count(reader) {
            try Task.checkCancellation()
            var stat = jsti_zip_entry()
            guard jsti_zip_stat(reader, index, &stat) != 0,
                  stat.filename_bytes > 1, stat.filename_bytes <= 1 << 20 else {
                throw DataMigrationError.invalid("Invalid ZIP entry metadata.")
            }
            var name = [CChar](repeating: 0, count: Int(stat.filename_bytes))
            guard jsti_zip_filename(reader, index, &name, stat.filename_bytes) == stat.filename_bytes else {
                throw DataMigrationError.invalid("Cannot read the ZIP entry name.")
            }
            let bytes = name.dropLast().map { UInt8(bitPattern: $0) }
            guard !bytes.contains(0), let path = String(bytes: bytes, encoding: .utf8) else {
                throw DataMigrationError.invalid("A ZIP entry has an invalid UTF-8 name.")
            }
            entries.append(.init(
                index: index, path: path, bytes: stat.uncompressed_bytes, regular: stat.regular_file != 0
            ))
        }
        _ = try DataMigrationArchivePolicy.preflight(entries.lazy.map {
            .init(path: $0.path, uncompressedBytes: $0.bytes)
        })
        return entries
    }

    private static let read: jsti_zip_read = { opaque, offset, buffer, count in
        guard let opaque, let buffer else { return 0 }
        let input = Unmanaged<DesktopMigrationZipInput>.fromOpaque(opaque).takeUnretainedValue()
        do {
            try Task.checkCancellation()
            try input.file.seek(toOffset: offset)
            let bytes = try input.file.read(upToCount: count) ?? Data()
            bytes.withUnsafeBytes {
                if let source = $0.baseAddress { buffer.copyMemory(from: source, byteCount: $0.count) }
            }
            return bytes.count
        } catch {
            input.failure = error
            return 0
        }
    }

    private static let write: jsti_zip_consume = { opaque, offset, buffer, count in
        guard let opaque, let buffer else { return 0 }
        let output = Unmanaged<DesktopMigrationZipOutput>.fromOpaque(opaque).takeUnretainedValue()
        do {
            try Task.checkCancellation()
            guard offset == output.count, UInt64(count) <= output.limit - output.count else {
                throw DataMigrationError.invalid("The ZIP entry exceeds its extraction budget.")
            }
            try output.consume(Data(bytes: buffer, count: count))
            output.count += UInt64(count)
            return count
        } catch {
            output.failure = error
            return 0
        }
    }
}
