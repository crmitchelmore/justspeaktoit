import Foundation
import SpeakCore

/// The on-disk state of one downloaded model file.
public enum LocalModelInstallState: Equatable, Sendable {
    case notInstalled
    /// Bytes of the pinned artefact kept from an interrupted download.
    case partial(received: Int64, total: Int64)
    /// The verified file and its receipt are in place.
    case installed
}

public enum LocalModelInstallError: LocalizedError, Equatable {
    case checksumMismatch
    case sizeMismatch(expected: Int64, actual: Int64)
    case notInstalled(String)
    case unsafeFileName(String)

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch:
            return "The downloaded model does not match its pinned SHA-256, so it was deleted. Download it again."
        case .sizeMismatch(let expected, let actual):
            return "The model file is \(actual) bytes instead of the pinned \(expected). Download it again."
        case .notInstalled(let name):
            return "\(name) is not downloaded. Open Local models to download it."
        case .unsafeFileName(let name):
            return "Refusing to install a model file with an unsafe name: \(name)"
        }
    }
}

/// A persisted record that a file was verified against its pinned digest.
public struct LocalModelInstallReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let identifier: String
    public let filename: String
    public let byteCount: Int64
    public let sha256: String
    public let source: String
    public let verifiedAt: Date
}

/// Downloads, resumes, verifies and removes pinned single-file models.
///
/// Every file lives in its own directory below `root`. A download streams into
/// `<file>.<digest prefix>.partial`, which survives cancellation, network
/// failure and restarts so the next attempt resumes with an HTTP range request.
/// The complete file is hashed with the platform SHA-256, and only a matching
/// file is renamed into place (an atomic rename in the same directory) before
/// its receipt is written atomically. A mismatch deletes the partial file.
/// Callers serialise operations on one model; different models are independent.
public struct LocalModelInstaller: Sendable {
    public struct Item: Sendable, Equatable {
        public let identifier: String
        public let displayName: String
        public let artifact: LocalModelFileArtifact

        public init(identifier: String, displayName: String, artifact: LocalModelFileArtifact) {
            self.identifier = identifier
            self.displayName = displayName
            self.artifact = artifact
        }

        public init(_ model: WhisperCppModel) {
            self.init(identifier: model.catalogueID, displayName: model.displayName, artifact: model.artifact)
        }
    }

    public typealias Progress = @Sendable (_ received: Int64, _ total: Int64) -> Void

    public let root: URL
    public let digests: LocalModelDigestProvider
    public let transport: LocalModelDownloadTransport
    /// Creates a directory with the host's private permissions.
    public let prepareDirectory: @Sendable (URL) throws -> Void

    public init(
        root: URL, digests: LocalModelDigestProvider, transport: LocalModelDownloadTransport,
        prepareDirectory: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    ) {
        self.root = root
        self.digests = digests
        self.transport = transport
        self.prepareDirectory = prepareDirectory
    }

    static let receiptName = "install-receipt.json"

    public func directory(for item: Item) -> URL {
        root.appendingPathComponent(Self.directoryName(for: item.identifier), isDirectory: true)
    }

    /// A stable, filesystem-safe directory name for an identifier.
    static func directoryName(for identifier: String) -> String {
        let slug = String(identifier.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return String(slug.prefix(120))
    }

    public func fileURL(for item: Item) -> URL {
        directory(for: item).appendingPathComponent(item.artifact.filename)
    }

    func partialURL(for item: Item) -> URL {
        directory(for: item)
            .appendingPathComponent("\(item.artifact.filename).\(item.artifact.sha256.prefix(16)).partial")
    }

    func receiptURL(for item: Item) -> URL {
        directory(for: item).appendingPathComponent(Self.receiptName)
    }

    public func state(of item: Item) -> LocalModelInstallState {
        if (try? verifiedFile(for: item)) != nil { return .installed }
        let partial = size(of: partialURL(for: item)) ?? 0
        if partial > 0, partial <= item.artifact.byteCount {
            return .partial(received: partial, total: item.artifact.byteCount)
        }
        return .notInstalled
    }

    /// The installed file, after checking its receipt and size. The full
    /// digest was checked when the receipt was written; `verify(_:)` rehashes.
    public func verifiedFile(for item: Item) throws -> URL {
        let file = fileURL(for: item)
        guard let data = try? Data(contentsOf: receiptURL(for: item)),
              let receipt = try? Self.decoder.decode(LocalModelInstallReceipt.self, from: data),
              receipt.identifier == item.identifier, receipt.filename == item.artifact.filename,
              receipt.sha256 == item.artifact.sha256, receipt.byteCount == item.artifact.byteCount else {
            throw LocalModelInstallError.notInstalled(item.displayName)
        }
        guard let actual = size(of: file) else { throw LocalModelInstallError.notInstalled(item.displayName) }
        guard actual == item.artifact.byteCount else {
            throw LocalModelInstallError.sizeMismatch(expected: item.artifact.byteCount, actual: actual)
        }
        return file
    }

    /// Rehashes the installed file; a mismatch removes it and its receipt.
    public func verify(_ item: Item) throws {
        let file = try verifiedFile(for: item)
        guard try digests.sha256(ofFileAt: file) == item.artifact.sha256 else {
            try? FileManager.default.removeItem(at: receiptURL(for: item))
            try? FileManager.default.removeItem(at: file)
            throw LocalModelInstallError.checksumMismatch
        }
    }

    /// Downloads (or resumes) and verifies `item`, returning the installed file.
    /// Cancellation keeps the partial bytes for the next attempt.
    @discardableResult
    public func install(_ item: Item, progress: @escaping Progress = { _, _ in }) async throws -> URL {
        let artifact = item.artifact
        guard Self.isSafeFileName(artifact.filename) else {
            throw LocalModelInstallError.unsafeFileName(artifact.filename)
        }
        if let file = try? verifiedFile(for: item) { return file }
        let directory = directory(for: item)
        try prepareDirectory(directory)
        try removeStaleFiles(for: item)
        let partial = partialURL(for: item)
        var offset = size(of: partial) ?? 0
        if offset > artifact.byteCount {
            try FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if offset < artifact.byteCount {
            try await download(item, into: partial, from: offset, progress: progress)
        }
        progress(artifact.byteCount, artifact.byteCount)
        try Task.checkCancellation()
        let actual = size(of: partial) ?? 0
        guard actual == artifact.byteCount else {
            throw LocalModelInstallError.sizeMismatch(expected: artifact.byteCount, actual: actual)
        }
        guard try digests.sha256(ofFileAt: partial) == artifact.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw LocalModelInstallError.checksumMismatch
        }
        let file = fileURL(for: item)
        try FileManager.default.moveItem(at: partial, to: file)
        let receipt = LocalModelInstallReceipt(
            schemaVersion: 1, identifier: item.identifier, filename: artifact.filename,
            byteCount: artifact.byteCount, sha256: artifact.sha256, source: artifact.url.absoluteString,
            verifiedAt: Date()
        )
        try Self.encoder.encode(receipt).write(to: receiptURL(for: item), options: .atomic)
        return file
    }

    /// Removes the installed file, its receipt and any partial download.
    public func remove(_ item: Item) throws {
        let directory = directory(for: item)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func download(
        _ item: Item, into partial: URL, from offset: Int64, progress: @escaping Progress
    ) async throws {
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
            }
        }
        let writer = PartialFileWriter(
            handle: try FileHandle(forWritingTo: partial), total: item.artifact.byteCount, progress: progress
        )
        defer { writer.close() }
        let request = LocalModelDownloadRequest(
            url: item.artifact.url, expectedByteCount: item.artifact.byteCount,
            allowedHosts: item.artifact.allowedHosts, resumeOffset: offset
        )
        try await transport.download(
            request, start: { try writer.begin($0, requestedOffset: offset) }, sink: { try writer.append($0) }
        )
        try writer.synchronize()
    }

    /// Deletes an unverified final file, a stale receipt and partial files of
    /// other artefacts, so a different pinned revision never resumes old bytes.
    private func removeStaleFiles(for item: Item) throws {
        let manager = FileManager.default
        let directory = directory(for: item)
        let keep = partialURL(for: item).lastPathComponent
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name != keep {
            try manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name == name.trimmingCharacters(in: .whitespaces)
            && !name.hasPrefix(".") && !name.hasSuffix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Receives body chunks serially from the transport's delegate queue.
private final class PartialFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let total: Int64
    private let progress: LocalModelInstaller.Progress
    private let lock = NSLock()
    private var written: Int64 = 0
    private var published: Int64 = 0
    private var closed = false

    init(handle: FileHandle, total: Int64, progress: @escaping LocalModelInstaller.Progress) {
        self.handle = handle
        self.total = total
        self.progress = progress
    }

    func begin(_ start: LocalModelDownloadStart, requestedOffset: Int64) throws {
        try lock.withLock {
            switch start {
            case .fromBeginning:
                try handle.truncate(atOffset: 0)
                written = 0
            case .resumed(let offset):
                guard offset == requestedOffset else { throw LocalModelDownloadError.rangeRefused }
                try handle.truncate(atOffset: UInt64(offset))
                written = offset
            }
            try handle.seekToEnd()
        }
        progress(written, total)
    }

    func append(_ data: Data) throws {
        let current = try lock.withLock { () -> Int64 in
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            return written
        }
        if current - published >= max(total / 200, 1 << 20) || current == total {
            published = current
            progress(current, total)
        }
    }

    func synchronize() throws {
        try lock.withLock { try handle.synchronize() }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
    }
}
