#if !os(Windows)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The local model store on POSIX systems: 0700 directories, 0600 files,
/// exclusive creation and no-follow opens. Windows uses its native adapter.
public struct LocalModelPOSIXFileSystem: LocalModelFileSystem {
    public init() {}

    public func preparePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw LocalModelStoreError.fileSystem("Could not create \(url.lastPathComponent) (errno \(errno)).")
        }
        guard itemKind(url) == .directory else { throw LocalModelStoreError.unsafeLocation(url.lastPathComponent) }
        let owner = try FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountID] as? NSNumber
        guard owner?.uint32Value == geteuid(), chmod(url.path, 0o700) == 0 else {
            throw LocalModelStoreError.unsafeLocation(url.lastPathComponent)
        }
    }

    public func createFile(_ url: URL) throws -> LocalModelFileWriter {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw LocalModelStoreError.fileSystem("Could not create \(url.lastPathComponent) (errno \(errno)).")
        }
        return POSIXWriter(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), url: url)
    }

    public func openForReading(_ url: URL) throws -> LocalModelFileReader {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LocalModelStoreError.fileSystem("Could not open \(url.lastPathComponent) (errno \(errno)).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard case .regularFile(let size) = itemKind(url) else {
            try? handle.close()
            throw LocalModelStoreError.unsafeLocation(url.lastPathComponent)
        }
        return POSIXReader(handle: handle, byteCount: size)
    }

    public func itemKind(_ url: URL) -> LocalModelItemKind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?: return .directory
        case .typeRegular?: return .regularFile((attributes[.size] as? NSNumber)?.int64Value ?? 0)
        default: return .other
        }
    }

    public func contentsOfDirectory(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    public func moveItem(from source: URL, to destination: URL) throws {
        guard itemKind(destination) == .missing else {
            throw LocalModelStoreError.fileSystem("\(destination.lastPathComponent) already exists.")
        }
        guard rename(source.path, destination.path) == 0 else {
            throw LocalModelStoreError.fileSystem("Could not rename \(source.lastPathComponent) (errno \(errno)).")
        }
    }

    public func replaceFile(_ url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".replace-\(UUID().uuidString)")
        try writeNewFile(temporary, data: data)
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw LocalModelStoreError.fileSystem("Could not replace \(url.lastPathComponent) (errno \(errno)).")
        }
    }

    public func removeTree(_ url: URL, within root: URL) throws {
        let parent = root.standardizedFileURL.pathComponents
        let child = url.standardizedFileURL.pathComponents
        guard child.count > parent.count, Array(child.prefix(parent.count)) == parent else {
            throw LocalModelStoreError.unsafeLocation(url.lastPathComponent)
        }
        guard itemKind(url) != .missing else { return }
        // FileManager removes a symbolic link itself rather than its target.
        try FileManager.default.removeItem(at: url)
    }
}

private final class POSIXWriter: LocalModelFileWriter {
    private let handle: FileHandle
    private let url: URL
    private var open = true

    init(handle: FileHandle, url: URL) {
        self.handle = handle
        self.url = url
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try handle.write(contentsOf: Data(bytes))
    }

    func commit() throws {
        guard open else { return }
        open = false
        try handle.synchronize()
        try handle.close()
    }

    func discard() {
        guard open else { return }
        open = false
        try? handle.close()
        unlink(url.path)
    }
}

private final class POSIXReader: LocalModelFileReader {
    private let handle: FileHandle
    let byteCount: Int64

    init(handle: FileHandle, byteCount: Int64) {
        self.handle = handle
        self.byteCount = byteCount
    }

    func read(maximum: Int) throws -> Data? {
        guard let data = try handle.read(upToCount: maximum), !data.isEmpty else { return nil }
        return data
    }

    func rewind() throws {
        try handle.seek(toOffset: 0)
    }

    func close() {
        try? handle.close()
    }
}
#endif
