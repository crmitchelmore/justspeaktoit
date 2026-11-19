import Foundation

/// Read-only access to fixed relative files beneath a caller's already-owned app-data directory.
/// The caller must suspend relevant source mutation; metadata fences are not atomic file authority.
public enum DesktopOwnedAppDataFileReader {
    public struct Snapshot: Sendable {
        public let data: Data
        public let receipt: Receipt
    }

    /// Sealed point-in-time metadata evidence, not byte binding, a held file, or write authority.
    public struct Receipt: Sendable {
        let location: Location
        let identity: DesktopRecordingAudioSnapshot.Identity
        let maximumBytes: UInt64
    }

    struct Location: Sendable {
        let root: URL
        let path: String
        let parents: [URL]
        var parent: URL { parents[parents.count - 1] }
        var file: URL { root.appendingPathComponent(path) }
    }

    /// Nil means absent, not unreadable or damaged. Bytes are returned without codec interpretation.
    public static func read(
        _ relativePath: String, appDirectory: URL, maximumBytes: UInt64,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Snapshot? {
        try checkCancellation()
        let location = try location(relativePath, root: appDirectory)
        for parent in location.parents {
            guard try directoryAttributes(parent) != nil else { return nil }
        }
        guard let identity = try sourceIdentity(location.file) else { return nil }
        guard identity.size <= maximumBytes else { throw DesktopOwnedAppDataFileReadError.exceedsByteBudget }
        try checkCancellation()
        let handle = try FileHandle(forReadingFrom: location.file)
        let data: Data
        let receipt = Receipt(location: location, identity: identity, maximumBytes: maximumBytes)
        do {
            data = try read(handle, maximumBytes: identity.size, checkCancellation: checkCancellation)
            guard UInt64(data.count) == identity.size else { throw DesktopOwnedAppDataFileReadError.changedSource }
            try validate(receipt)
        } catch {
            let original = error
            do { try handle.close() } catch {
                throw DesktopOwnedAppDataFileReadError.closeFailure(original: original, cleanup: error)
            }
            throw original
        }
        try handle.close()
        try checkCancellation()
        return Snapshot(data: data, receipt: receipt)
    }

    /// Rechecks the original metadata fence only. Use strict mode for byte/parent-chain binding.
    public static func revalidate(
        _ receipt: Receipt, checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        try validate(receipt)
        try checkCancellation()
    }

    static func location(_ path: String, root: URL) throws -> Location {
        guard root.isFileURL, !root.path.utf8.contains(0) else {
            throw DesktopOwnedAppDataFileReadError.invalidLocation
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.contains("\\"), !path.contains(":"), !path.utf8.contains(0),
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ")
              }) else {
            throw DesktopOwnedAppDataFileReadError.invalidRelativePath
        }
        let root = root.standardizedFileURL
        var parents = [root]
        for component in components.dropLast() {
            parents.append(parents[parents.count - 1].appendingPathComponent(component, isDirectory: true))
        }
        return Location(root: root, path: path, parents: parents)
    }

    static func sourceIdentity(_ url: URL) throws -> DesktopRecordingAudioSnapshot.Identity? {
        do {
            return try ownedIdentity(url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func ownedIdentity(_ url: URL) throws -> DesktopRecordingAudioSnapshot.Identity {
        do {
            return try DesktopRecordingStore.audioCleanupIdentity(at: url)
        } catch DesktopRecordingAudioCleanupError.unsafeFile {
            throw DesktopOwnedAppDataFileReadError.unsafeFile
        }
    }

    static func directoryAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
                throw DesktopOwnedAppDataFileReadError.unsafeDirectory
            }
            return attributes
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func validate(_ receipt: Receipt) throws {
        let current = try ownedIdentity(receipt.location.file)
        guard current == receipt.identity, try directoryAttributes(receipt.location.parent) != nil else {
            throw DesktopOwnedAppDataFileReadError.changedSource
        }
    }

    private static func read(
        _ handle: FileHandle, maximumBytes: UInt64, checkCancellation: () throws -> Void
    ) throws -> Data {
        var result = Data()
        while true {
            try checkCancellation()
            let remaining = maximumBytes - UInt64(result.count)
            let requested = remaining >= 65_536 ? 65_536 : remaining + 1
            guard let chunk = try handle.read(upToCount: Int(requested)), !chunk.isEmpty else { break }
            result.append(chunk)
            guard UInt64(result.count) <= maximumBytes else { throw DesktopOwnedAppDataFileReadError.grewSource }
        }
        return result
    }
}
