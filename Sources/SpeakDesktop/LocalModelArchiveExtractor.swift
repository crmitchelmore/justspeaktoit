import Foundation
import SpeakCore

/// Expands exactly one compressed stream. Implementations wrap audited
/// native code (upstream libbz2 on Windows); none is implemented here.
public protocol LocalModelArchiveDecompressor: Sendable {
    /// Pulls compressed input from `read` (nil marks its end) and passes
    /// expanded bytes to `write`. Throws for corrupt input, for any input
    /// after the end of the stream, or when output exceeds the bound.
    /// Returns the number of expanded bytes.
    func expand(
        read: () throws -> Data?, maximumOutputBytes: Int64,
        write: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Int64
}

/// A file written by extraction, verified against its pin.
public struct LocalModelExtractedFile: Equatable, Sendable {
    public let pinned: LocalModelPinnedFile
    public let url: URL
}

/// Expands a pinned archive, admitting only its exact listing.
///
/// Every entry is checked against the pin by name (exact case), kind and
/// size before its bytes are read, and every file's SHA-256 is verified.
/// Files in `installedFiles` are written flat into the destination by file
/// name; the rest are verified and discarded. On any failure the partial
/// output of the current file is removed; the caller owns the directory.
public struct LocalModelArchiveExtractor {
    public static let chunkSize = 1 << 20

    public let archive: LocalModelPinnedArchive
    public let installedFiles: [LocalModelPinnedFile]
    let fileSystem: LocalModelFileSystem
    let digests: LocalModelDigestProvider
    let decompressor: LocalModelArchiveDecompressor

    public init(
        archive: LocalModelPinnedArchive, installedFiles: [LocalModelPinnedFile],
        fileSystem: LocalModelFileSystem, digests: LocalModelDigestProvider,
        decompressor: LocalModelArchiveDecompressor
    ) {
        self.archive = archive
        self.installedFiles = installedFiles
        self.fileSystem = fileSystem
        self.digests = digests
        self.decompressor = decompressor
    }

    public func extract(
        from source: LocalModelFileReader, into directory: URL,
        cancellation: LocalModelCancellation, progress: (Int64) -> Void = { _ in }
    ) throws -> [LocalModelExtractedFile] {
        let session = try ExtractionSession(extractor: self, directory: directory, cancellation: cancellation)
        defer { session.abandonCurrentFile() }
        let reader = LocalModelTarReader(
            onEntry: { try session.begin($0) },
            onData: { try session.append($0) },
            onEntryEnd: { try session.end() }
        )
        var consumed: Int64 = 0
        let expanded = try decompressor.expand(
            read: {
                try cancellation.check()
                guard let chunk = try source.read(maximum: Self.chunkSize) else { return nil }
                consumed += Int64(chunk.count)
                progress(consumed)
                return chunk
            },
            maximumOutputBytes: archive.expandedByteCount,
            write: { try reader.consume($0) }
        )
        try reader.finish()
        guard expanded == archive.expandedByteCount, consumed == archive.byteCount else {
            throw LocalModelArchiveError.expandedSizeMismatch
        }
        try session.verifyComplete()
        return session.extracted
    }
}

private final class ExtractionSession {
    private struct Expected {
        let kind: LocalModelTarReader.Entry.Kind
        let path: String
        let file: LocalModelPinnedFile?
    }

    private struct Current {
        let file: LocalModelPinnedFile
        let hasher: LocalModelSHA256Hasher
        let writer: LocalModelFileWriter?
        let url: URL?
        var written: Int64 = 0
    }

    private let extractor: LocalModelArchiveExtractor
    private let directory: URL
    private let cancellation: LocalModelCancellation
    private var expected: [String: Expected] = [:]
    private var installed: Set<String>
    private var seen: Set<String> = []
    private var current: Current?
    private(set) var extracted: [LocalModelExtractedFile] = []

    init(extractor: LocalModelArchiveExtractor, directory: URL, cancellation: LocalModelCancellation) throws {
        self.extractor = extractor
        self.directory = directory
        self.cancellation = cancellation
        let archive = extractor.archive
        installed = Set(extractor.installedFiles.map(\.path))
        let names = extractor.installedFiles.map { $0.filename.lowercased() }
        guard Set(names).count == names.count,
              extractor.installedFiles.allSatisfy({ archive.file(at: $0.path) == $0 }) else {
            throw LocalModelStoreError.invalidPackage
        }
        add(.directory, path: archive.rootDirectory, file: nil)
        for path in archive.directories { add(.directory, path: archive.rootDirectory + "/" + path, file: nil) }
        for file in archive.files { add(.file, path: archive.rootDirectory + "/" + file.path, file: file) }
    }

    private func add(_ kind: LocalModelTarReader.Entry.Kind, path: String, file: LocalModelPinnedFile?) {
        expected[path.lowercased()] = Expected(kind: kind, path: path, file: file)
    }

    func begin(_ entry: LocalModelTarReader.Entry) throws {
        try cancellation.check()
        let path = entry.components.joined(separator: "/")
        let key = LocalModelArchivePath.collisionKey(entry.components)
        guard seen.insert(key).inserted else { throw LocalModelArchiveError.duplicateEntry(path) }
        guard let match = expected[key], match.path == path, match.kind == entry.kind else {
            throw LocalModelArchiveError.unexpectedEntry(path)
        }
        guard let file = match.file else { return }
        guard entry.size == file.byteCount else { throw LocalModelArchiveError.sizeMismatch(file.path) }
        let hasher = try extractor.digests.makeSHA256()
        var writer: LocalModelFileWriter?
        var url: URL?
        if installed.contains(file.path) {
            let destination = directory.appendingPathComponent(file.filename)
            writer = try extractor.fileSystem.createFile(destination)
            url = destination
        }
        current = Current(file: file, hasher: hasher, writer: writer, url: url)
    }

    func append(_ bytes: UnsafeRawBufferPointer) throws {
        guard var entry = current else { return }
        try cancellation.check()
        try entry.hasher.update(bytes)
        try entry.writer?.write(bytes)
        entry.written += Int64(bytes.count)
        current = entry
    }

    func end() throws {
        guard let entry = current else { return }
        guard entry.written == entry.file.byteCount else { throw LocalModelArchiveError.sizeMismatch(entry.file.path) }
        guard try entry.hasher.finish() == entry.file.sha256 else {
            throw LocalModelArchiveError.digestMismatch(entry.file.path)
        }
        try entry.writer?.commit()
        current = nil
        if let url = entry.url { extracted.append(LocalModelExtractedFile(pinned: entry.file, url: url)) }
    }

    func verifyComplete() throws {
        if let missing = expected.first(where: { !seen.contains($0.key) }) {
            throw LocalModelArchiveError.missingEntry(missing.value.path)
        }
    }

    func abandonCurrentFile() {
        current?.writer?.discard()
        current = nil
    }
}
