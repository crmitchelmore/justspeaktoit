import Foundation

/// An exclusively created file in a new private UUID folder, not a path-based write grant.
/// Implementations must hold the file and its private directory until `close`.
public protocol DesktopOwnedCaptureWriter: AnyObject, Sendable {
    var url: URL { get }
    func write(_ data: Data) throws
    func seek(toOffset offset: UInt64) throws
    func synchronize() throws
    func validateLocation() throws
    /// Removes only this unpublished file through its held private directory.
    /// A changed file must be kept, and reported, rather than removed.
    func removeUnpublished() throws
    func close() throws
}

public enum DesktopOwnedCaptureError: Error, LocalizedError, Sendable {
    case unsupportedPlatform
    case unsafeDirectory
    case changedLocation
    case closed
    case alreadyRetained
    case notFresh
    case cleanupFailure(original: String, cleanup: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "Held-file recording creation is not implemented on this platform."
        case .unsafeDirectory: return "The selected recording folder has linked or insecure ancestry."
        case .changedLocation: return "The owned recording file or its directory was replaced."
        case .closed: return "The owned recording file is closed."
        case .alreadyRetained: return "Retained recording audio cannot be discarded as unpublished capture."
        case .notFresh: return "PCM initialization requires a new, unused capture file."
        case let .cleanupFailure(original, cleanup):
            return "\(original) Unpublished capture cleanup also failed: \(cleanup)"
        }
    }
}

/// Serialized lifetime of one native writer. No configuration, metadata or imported
/// path can manufacture this capability. A factory is an explicit trusted host adapter.
public final class DesktopOwnedCaptureFile: @unchecked Sendable {
    public struct Factory: Sendable {
        let create: @Sendable (URL, UUID, UUID) throws -> any DesktopOwnedCaptureWriter

        public init(create: @escaping @Sendable (URL, UUID, UUID) throws -> any DesktopOwnedCaptureWriter) {
            self.create = create
        }

        /// Other hosts fail closed until their held-file security adapters are qualified.
        public static var native: Self {
            #if os(Linux) && canImport(Glibc)
            Self { try DesktopPOSIXCaptureWriter(root: $0, directoryID: $1, recordingID: $2) }
            #else
            Self { _, _, _ in throw DesktopOwnedCaptureError.unsupportedPlatform }
            #endif
        }
    }

    public let url: URL
    private let writer: any DesktopOwnedCaptureWriter
    private let lock = NSLock()
    private var retained = false
    private var ownershipPublished = false
    private var closed = false
    private var pristine = true

    public static func create(
        in root: URL, directoryID: UUID = UUID(), recordingID: UUID = UUID(), using factory: Factory = .native,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopOwnedCaptureFile {
        try checkCancellation()
        let file = try DesktopOwnedCaptureFile(writer: factory.create(root, directoryID, recordingID))
        do {
            try checkCancellation()
            return file
        } catch {
            let original = error
            do { try file.discard() } catch {
                throw DesktopOwnedCaptureError.cleanupFailure(
                    original: original.localizedDescription, cleanup: error.localizedDescription
                )
            }
            throw original
        }
    }

    private init(writer: any DesktopOwnedCaptureWriter) throws {
        self.writer = writer
        self.url = writer.url
        do { try writer.validateLocation() } catch {
            let original = error
            closed = true
            do { try cleanup(writer) } catch {
                throw DesktopOwnedCaptureError.cleanupFailure(
                    original: original.localizedDescription, cleanup: error.localizedDescription
                )
            }
            throw original
        }
    }

    deinit { try? close() }

    public func write(_ data: Data) throws {
        try locked {
            pristine = false
            try writer.write(data)
        }
    }

    public func seek(toOffset offset: UInt64) throws {
        try locked {
            pristine = false
            try writer.seek(toOffset: offset)
        }
    }

    public func synchronize() throws {
        try locked {
            try writer.validateLocation()
            try writer.synchronize()
        }
    }

    /// Transfers audio to the recording/recovery lifetime without closing or reopening it.
    /// Thereafter cancellation and destruction close the handle but never delete audio.
    public func retain() throws {
        try locked {
            try writer.validateLocation()
            retained = true
        }
    }

    /// Registry publication preserves recovery audio, but still permits its first PCM initialization.
    func markOwnershipPublished() {
        lock.withLock { ownershipPublished = true }
    }

    func initializePCM(header: Data) throws {
        try locked {
            guard pristine, !retained else { throw DesktopOwnedCaptureError.notFresh }
            pristine = false
            do {
                try writer.validateLocation()
                try writer.write(header)
                try writer.validateLocation()
                retained = true
            } catch {
                let original = error
                closed = true
                do {
                    if ownershipPublished { try writer.close() } else { try cleanup(writer) }
                } catch {
                    throw DesktopOwnedCaptureError.cleanupFailure(
                        original: original.localizedDescription, cleanup: error.localizedDescription
                    )
                }
                throw original
            }
        }
    }

    /// Cancellation applies only before retention. Cleanup uses the native owned
    /// container, never `url`, even when the selected root has since been renamed.
    public func discard() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw DesktopOwnedCaptureError.closed }
        guard !retained, !ownershipPublished else { throw DesktopOwnedCaptureError.alreadyRetained }
        closed = true
        try cleanup(writer)
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if retained || ownershipPublished { try writer.close() } else { try cleanup(writer) }
    }

    private func locked(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw DesktopOwnedCaptureError.closed }
        try body()
    }

    private func cleanup(_ writer: any DesktopOwnedCaptureWriter) throws {
        var removalError: Error?
        do { try writer.removeUnpublished() } catch { removalError = error }
        do { try writer.close() } catch {
            if let removalError {
                throw DesktopOwnedCaptureError.cleanupFailure(
                    original: removalError.localizedDescription, cleanup: error.localizedDescription
                )
            }
            throw error
        }
        if let removalError { throw removalError }
    }
}
