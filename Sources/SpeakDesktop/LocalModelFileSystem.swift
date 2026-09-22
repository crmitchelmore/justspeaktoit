import Foundation

/// A new, exclusively created private file being written.
public protocol LocalModelFileWriter: AnyObject {
    func write(_ bytes: UnsafeRawBufferPointer) throws
    /// Flushes to stable storage and closes, keeping the file.
    func commit() throws
    /// Closes and removes the partial file. Never throws; best effort.
    func discard()
}

/// An open regular file. Where the platform allows, writers, renames and
/// deletion are refused for as long as the reader stays open, so the bytes
/// that were verified are the bytes that are used.
public protocol LocalModelFileReader: AnyObject {
    var byteCount: Int64 { get }
    /// Up to `maximum` bytes from the current position, or nil at the end.
    func read(maximum: Int) throws -> Data?
    /// Returns to the start of the file.
    func rewind() throws
    func close()
}

public enum LocalModelItemKind: Equatable, Sendable {
    case missing
    case directory
    case regularFile(Int64)
    /// A link, junction, device or anything else that is never followed.
    case other
}

/// Filesystem operations for the local model store, implemented natively on
/// Windows (private ACLs, handle-based writes, no reparse traversal) and with
/// POSIX permissions elsewhere.
public protocol LocalModelFileSystem: Sendable {
    /// Creates or repairs `url` as a directory only the current user (and,
    /// on Windows, SYSTEM) can open. Its parent must already exist.
    func preparePrivateDirectory(_ url: URL) throws
    /// Creates `url` exclusively; an existing file is never opened.
    func createFile(_ url: URL) throws -> LocalModelFileWriter
    func openForReading(_ url: URL) throws -> LocalModelFileReader
    func itemKind(_ url: URL) -> LocalModelItemKind
    func contentsOfDirectory(_ url: URL) throws -> [String]
    /// Renames without replacing an existing destination.
    func moveItem(from source: URL, to destination: URL) throws
    /// Atomically replaces the small file at `url` with `data`.
    func replaceFile(_ url: URL, with data: Data) throws
    /// Removes `url` and everything below it without following links. The
    /// path must lie strictly inside `root`.
    func removeTree(_ url: URL, within root: URL) throws
}

extension LocalModelFileSystem {
    /// Reads a small file completely, refusing anything larger than the bound.
    public func readSmallFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let reader = try openForReading(url)
        defer { reader.close() }
        guard reader.byteCount <= Int64(maximumBytes) else { throw LocalModelStoreError.corruptRecord }
        var data = Data()
        while let chunk = try reader.read(maximum: maximumBytes) {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw LocalModelStoreError.corruptRecord }
        }
        return data
    }

    /// Creates `url` with exactly `data`.
    public func writeNewFile(_ url: URL, data: Data) throws {
        let writer = try createFile(url)
        do {
            try data.withUnsafeBytes { try writer.write($0) }
            try writer.commit()
        } catch {
            writer.discard()
            throw error
        }
    }
}

/// Cooperative cancellation shared with blocking file and native work.
///
/// Work that publishes a result claims its commit point first: from then on
/// cancellation is too late and is ignored, so a cancelled operation either
/// publishes nothing or publishes completely, never a mixture.
public final class LocalModelCancellation: @unchecked Sendable {
    private enum State { case running, cancelled, committed }

    private let lock = NSLock()
    private var state = State.running

    public init() {}

    public var isCancelled: Bool { lock.withLock { state == .cancelled } }

    /// Returns false when the work had already claimed its commit point.
    @discardableResult
    public func cancel() -> Bool {
        lock.withLock {
            guard state != .committed else { return false }
            state = .cancelled
            return true
        }
    }

    /// Returns false when cancellation won; the caller must then discard.
    public func claimCommit() -> Bool {
        lock.withLock {
            guard state == .running else { return state == .committed }
            state = .committed
            return true
        }
    }

    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
