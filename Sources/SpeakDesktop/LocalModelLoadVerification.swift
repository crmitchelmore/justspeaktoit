import Foundation

/// What identifies an installed model file on disk between two hashes. Any
/// replacement gets a new file number, and writing in place changes the
/// modification time, so either makes a verified file need hashing again.
public struct LocalModelFileIdentity: Equatable, Sendable {
    public let byteCount: Int64
    public let modified: Date?
    /// The inode or NTFS file ID, and the volume holding it, where the platform reports them.
    public let fileNumber: UInt64?
    public let volume: UInt64?

    public init(byteCount: Int64, modified: Date?, fileNumber: UInt64?, volume: UInt64?) {
        self.byteCount = byteCount
        self.modified = modified
        self.fileNumber = fileNumber
        self.volume = volume
    }

    /// The identity of the regular file at `url`; nil when there is none.
    public init?(fileAt url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = Self.number(attributes[.size]) else { return nil }
        self.init(
            byteCount: Int64(bitPattern: size), modified: attributes[.modificationDate] as? Date,
            fileNumber: Self.number(attributes[.systemFileNumber]), volume: Self.number(attributes[.systemNumber])
        )
    }

    /// Foundation reports these as NSNumber on some platforms and as Swift integers on others.
    private static func number(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber: return number.uint64Value
        case let number as UInt64: return number
        case let number as Int64: return UInt64(bitPattern: number)
        case let number as UInt32: return UInt64(number)
        case let number as Int: return UInt64(bitPattern: Int64(number))
        default: return nil
        }
    }
}

/// Which installed model file was last hashed for the speech runtime to load.
///
/// The runtime keeps one model in memory and reads a model file only when it
/// loads it: on first use in a process, or after it held another model or
/// none. Hashing a large model before every recording would take seconds, so
/// a host rehashes a file before any recognition that may load it: whenever it
/// is not the file verified last, or its identity has changed since.
public struct LocalModelLoadVerification: Sendable {
    private struct Verified: Sendable {
        let path: String
        let identity: LocalModelFileIdentity
    }

    private var verified: Verified?

    public init() {}

    /// True when `file` is the one verified last and has not changed since.
    public func isCurrent(_ file: URL, identity: LocalModelFileIdentity) -> Bool {
        verified?.path == file.standardizedFileURL.path && verified?.identity == identity
    }

    /// `file` was just hashed with `identity`; any other file must be hashed again.
    public mutating func record(_ file: URL, identity: LocalModelFileIdentity) {
        verified = Verified(path: file.standardizedFileURL.path, identity: identity)
    }

    /// `file` was removed, replaced or failed a check, so it is hashed again before its next use.
    public mutating func forget(_ file: URL) {
        if verified?.path == file.standardizedFileURL.path { verified = nil }
    }
}

extension LocalModelInstaller {
    /// The installed file after `verifiedFile(for:)`, with its identity now.
    public func installedFile(for item: Item) throws -> (file: URL, identity: LocalModelFileIdentity) {
        let file = try verifiedFile(for: item)
        guard let identity = LocalModelFileIdentity(fileAt: file) else {
            throw LocalModelInstallError.notInstalled(item.displayName)
        }
        return (file, identity)
    }

    /// Rehashes the installed file before the speech runtime loads it and
    /// returns the identity it kept throughout. A digest mismatch removes the
    /// file and its receipt, as `verify(_:)` does; a file that changed while
    /// it was hashed is refused, since the digest may not describe it.
    public func verifyForLoading(_ item: Item) throws -> LocalModelFileIdentity {
        let (file, before) = try installedFile(for: item)
        try verify(item)
        guard LocalModelFileIdentity(fileAt: file) == before else {
            throw LocalModelInstallError.changedDuringVerification(item.displayName)
        }
        return before
    }
}
