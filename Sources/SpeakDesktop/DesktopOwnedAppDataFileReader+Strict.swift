import Foundation

extension DesktopOwnedAppDataFileReader {
    public struct StrictSnapshot: Sendable {
        /// Nil means absent; even absence has point-in-time read/revalidation evidence.
        public let data: Data?
        public let receipt: StrictReceipt
    }

    /// Sealed byte/file/directory-chain read evidence. Never a held file, atomic CAS, or write authority.
    public struct StrictReceipt: Sendable {
        let location: Location
        let maximumBytes: UInt64
        let data: Data?
        let identity: DesktopRecordingAudioSnapshot.Identity?
        let chain: [DirectoryState]
    }

    struct DirectoryIdentity: Equatable, Sendable {
        let device: UInt64
        let file: UInt64
        let modified: Date
        let created: Date?
    }

    struct DirectoryState: Equatable, Sendable {
        let url: URL
        let identity: DirectoryIdentity?
    }

    /// Opt-in stronger binding, using the same bounded reader. Codecs and digests remain caller-owned.
    /// Required device/file metadata missing on a platform is an explicit unsupported result.
    public static func readStrict(
        _ relativePath: String, appDirectory: URL, maximumBytes: UInt64,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> StrictSnapshot {
        try checkCancellation()
        let location = try location(relativePath, root: appDirectory)
        let before = try directoryChain(location, checkCancellation: checkCancellation)
        let initial = try strictSourceIdentity(location.file)
        let snapshot = try read(
            relativePath, appDirectory: appDirectory, maximumBytes: maximumBytes,
            checkCancellation: checkCancellation
        )
        let after = try directoryChain(location, checkCancellation: checkCancellation)
        let final = try strictSourceIdentity(location.file)
        guard before == after, initial == snapshot?.receipt.identity, initial == final else {
            throw DesktopOwnedAppDataFileReadError.changedSource
        }
        try checkCancellation()
        let receipt = StrictReceipt(
            location: location, maximumBytes: maximumBytes, data: snapshot?.data, identity: initial, chain: before
        )
        return StrictSnapshot(data: snapshot?.data, receipt: receipt)
    }

    /// Bounded reread compares exact bytes and identity, including missing sources and parents.
    /// Successful validation does not prevent a later change or authorize any publication/deletion.
    public static func revalidateStrict(
        _ receipt: StrictReceipt, checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        let current = try readStrict(
            receipt.location.path, appDirectory: receipt.location.root, maximumBytes: receipt.maximumBytes,
            checkCancellation: checkCancellation
        )
        guard current.data == receipt.data, current.receipt.identity == receipt.identity,
              current.receipt.chain == receipt.chain else {
            throw DesktopOwnedAppDataFileReadError.changedSource
        }
        try checkCancellation()
    }

    static func strictSourceIdentity(_ url: URL) throws -> DesktopRecordingAudioSnapshot.Identity? {
        let identity = try sourceIdentity(url)
        if let identity {
            try requireStrictIdentity(identity)
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let links = values[.referenceCount] as? NSNumber else {
                throw DesktopOwnedAppDataFileReadError.insufficientIdentity
            }
            guard links.uint64Value == 1 else { throw DesktopOwnedAppDataFileReadError.unsafeFile }
        }
        return identity
    }

    static func requireStrictIdentity(_ identity: DesktopRecordingAudioSnapshot.Identity) throws {
        guard identity.device != nil, let file = identity.file, file != 0 else {
            throw DesktopOwnedAppDataFileReadError.insufficientIdentity
        }
    }

    private static func directoryChain(
        _ location: Location, checkCancellation: () throws -> Void
    ) throws -> [DirectoryState] {
        let states = try location.parents.map { url in
            try checkCancellation()
            guard let values = try directoryAttributes(url) else { return DirectoryState(url: url, identity: nil) }
            guard let device = (values[.systemNumber] as? NSNumber)?.uint64Value,
                  let file = (values[.systemFileNumber] as? NSNumber)?.uint64Value,
                  file != 0, let modified = values[.modificationDate] as? Date else {
                throw DesktopOwnedAppDataFileReadError.insufficientIdentity
            }
            return DirectoryState(url: url, identity: .init(
                device: device, file: file, modified: modified, created: values[.creationDate] as? Date
            ))
        }
        guard states.first?.identity != nil else {
            throw DesktopOwnedAppDataFileReadError.insufficientIdentity
        }
        return states
    }
}
