import Foundation

public enum DesktopRecordingRegistryError: LocalizedError, Sendable {
    case unsupported, identityUnavailable, corrupt, foreign, missing, unexpectedLeaf, budget, closed, busy

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Native immutable recording registration storage is not qualified on this platform."
        case .identityUnavailable: return "Recording registration native identity compatibility cannot be verified."
        case .corrupt: return "A recording registration record is corrupt or uses an unsupported schema."
        case .foreign: return "A recording registration belongs to a different local namespace or History store."
        case .missing: return "The initialized recording registration namespace or required record is missing."
        case .unexpectedLeaf: return "The private recording namespace contains an unknown or incomplete publication."
        case .budget: return "The private recording namespace exceeds its bounded record or byte budget."
        case .closed: return "The native recording registration namespace is closed."
        case .busy: return "Another process owns the recording registration namespace."
        }
    }
}

public struct DesktopRecordingRegistryWriteFailure: LocalizedError, CustomStringConvertible, Sendable {
    public enum Effect: Sendable { case unpublished, published }
    public let primaryError: Error
    public let cleanupError: Error?
    public let effect: Effect

    public var errorDescription: String? { description }

    public var description: String {
        switch effect {
        case .unpublished: return "Recording registration publication failed before commit."
        case .published: return "Recording registration was published, but completion could not be confirmed."
        }
    }
}

/// Trusted native adapter boundary, not a read receipt or importer-granted write authority.
public protocol DesktopRecordingRegistryNamespace: AnyObject, Sendable {
    var historyDevice: UInt64 { get }
    var historyFile: UInt64 { get }
    var namespaceDevice: UInt64 { get }
    var namespaceFile: UInt64 { get }
    func names() throws -> [String]
    func read(_ name: String) throws -> Data
    func append(_ name: String, data: Data, checkCancellation: () throws -> Void) throws
    func validate() throws
    func close() throws
}

public struct DesktopRecordingRegistryFactory: Sendable {
    let open: @Sendable (URL, Bool) throws -> any DesktopRecordingRegistryNamespace

    public init(open: @escaping @Sendable (URL, Bool) throws -> any DesktopRecordingRegistryNamespace) {
        self.open = open
    }

    public static var native: Self {
        #if os(Linux) && canImport(Glibc)
        Self { try DesktopPOSIXRecordingRegistry(history: $0, initialize: $1) }
        #else
        Self { _, _ in throw DesktopRecordingRegistryError.unsupported }
        #endif
    }
}

/// An explicit private immutable namespace, never inferred from imported profile/History descriptors.
/// Blocking I/O must run on a host-owned cancellable worker; this does not install a host lifecycle gate.
public final class DesktopLocalRecordingPersistence: DesktopRecordingLocationPersistence, @unchecked Sendable {
    static let maximumRecords = 4_096
    static let maximumTotalBytes = 8 * 1_024 * 1_024
    private let namespace: any DesktopRecordingRegistryNamespace
    private let binding: DesktopRecordingLocationCodec.Binding
    private let checkCancellation: @Sendable () throws -> Void
    private let lock = NSLock()
    private var closed = false

    public static func initialize(
        historyDirectory: URL, using factory: DesktopRecordingRegistryFactory = .native,
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopLocalRecordingPersistence {
        try Self(history: historyDirectory, initialize: true, factory: factory, checkCancellation: checkCancellation)
    }

    public static func open(
        historyDirectory: URL, using factory: DesktopRecordingRegistryFactory = .native,
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopLocalRecordingPersistence {
        try Self(history: historyDirectory, initialize: false, factory: factory, checkCancellation: checkCancellation)
    }

    private init(
        history: URL, initialize: Bool, factory: DesktopRecordingRegistryFactory,
        checkCancellation: @escaping @Sendable () throws -> Void
    ) throws {
        try checkCancellation()
        let namespace = try factory.open(history, initialize)
        var headerPublished = false
        do {
            let identity = try DesktopRecordingLocationIdentity.directory(history)
            guard identity.device == namespace.historyDevice, identity.file == namespace.historyFile,
                  namespace.historyFile != 0, namespace.namespaceFile != 0 else {
                throw DesktopRecordingRegistryError.identityUnavailable
            }
            let namespaceIdentity = DesktopRecordingLocationIdentity(
                device: namespace.namespaceDevice, file: namespace.namespaceFile
            )
            let binding: DesktopRecordingLocationCodec.Binding
            if initialize {
                binding = .init(
                    id: UUID(), history: history.standardizedFileURL, historyIdentity: identity,
                    namespaceIdentity: namespaceIdentity
                )
                try namespace.append(
                    "registry.jloc",
                    data: DesktopRecordingLocationCodec.encode(.init(binding: binding, payload: .header)),
                    checkCancellation: checkCancellation
                )
                headerPublished = true
            } else {
                let header = try DesktopRecordingLocationCodec.decode(namespace.read("registry.jloc"))
                guard case .header = header.payload, header.binding.history == history.standardizedFileURL,
                      header.binding.historyIdentity == identity,
                      header.binding.namespaceIdentity == namespaceIdentity else {
                    throw DesktopRecordingRegistryError.foreign
                }
                binding = header.binding
            }
            try namespace.validate()
            self.namespace = namespace
            self.binding = binding
            self.checkCancellation = checkCancellation
        } catch {
            let primary: Error = headerPublished
                ? DesktopRecordingRegistryWriteFailure(primaryError: error, cleanupError: nil, effect: .published)
                : error
            do { try namespace.close() } catch {
                throw DesktopRecordingLocationCleanupFailure(primaryError: primary, cleanupError: error)
            }
            throw primary
        }
    }

    deinit { try? close() }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try namespace.close()
    }

    public func loadVerified() throws -> DesktopRecordingLocationState {
        lock.lock()
        defer { lock.unlock() }
        return try load()
    }

    public func appendRegistration(_ registration: DesktopRecordingLocationRegistration) throws {
        try append(.registration(registration))
    }

    public func appendRecording(_ recording: DesktopRecordingLocationOwnership) throws {
        try append(.ownership(recording))
    }

    private func append(_ payload: DesktopRecordingLocationCodec.Payload) throws {
        lock.lock()
        defer { lock.unlock() }
        let state = try load()
        switch payload {
        case .header: throw DesktopRecordingRegistryError.corrupt
        case let .registration(value):
            guard !state.registrations.contains(where: { $0.id == value.id }) else {
                throw DesktopRecordingLocationError.duplicateIdentity
            }
        case let .ownership(value):
            guard state.registrations.contains(where: { $0.id == value.reference.locationID }),
                  !state.recordings.contains(where: { $0.recordingID == value.recordingID }) else {
                throw DesktopRecordingLocationError.invalidReference
            }
        }
        let envelope = DesktopRecordingLocationCodec.Envelope(binding: binding, payload: payload)
        let data = try DesktopRecordingLocationCodec.encode(envelope)
        let names = try checkedNames()
        guard names.count < Self.maximumRecords else { throw DesktopRecordingRegistryError.budget }
        var bytes = data.count
        for name in names {
            try checkCancellation()
            bytes += try namespace.read(name).count
            guard bytes <= Self.maximumTotalBytes else { throw DesktopRecordingRegistryError.budget }
        }
        try namespace.append(envelope.filename, data: data, checkCancellation: checkCancellation)
    }

    private func load() throws -> DesktopRecordingLocationState {
        guard !closed else { throw DesktopRecordingRegistryError.closed }
        try checkCancellation()
        try namespace.validate()
        let names = try checkedNames()
        var registrations: [DesktopRecordingLocationRegistration] = []
        var recordings: [DesktopRecordingLocationOwnership] = []
        var bytes = 0
        for name in names.sorted() {
            try checkCancellation()
            let data = try namespace.read(name)
            bytes += data.count
            guard bytes <= Self.maximumTotalBytes else { throw DesktopRecordingRegistryError.budget }
            let envelope = try DesktopRecordingLocationCodec.decode(data)
            guard envelope.binding == binding, envelope.filename == name else {
                throw DesktopRecordingRegistryError.foreign
            }
            switch envelope.payload {
            case .header: break
            case let .registration(value): registrations.append(value)
            case let .ownership(value): recordings.append(value)
            }
        }
        let ids = Set(registrations.map(\.id))
        guard ids.count == registrations.count, Set(recordings.map(\.recordingID)).count == recordings.count,
              recordings.allSatisfy({ ids.contains($0.reference.locationID) }) else {
            throw DesktopRecordingRegistryError.foreign
        }
        try namespace.validate()
        return .init(verifiedRegistrations: registrations, verifiedRecordings: recordings)
    }

    private func checkedNames() throws -> [String] {
        let names = try namespace.names()
        guard names.count <= Self.maximumRecords else { throw DesktopRecordingRegistryError.budget }
        guard Set(names).count == names.count else { throw DesktopRecordingRegistryError.unexpectedLeaf }
        guard names.contains("registry.jloc") else { throw DesktopRecordingRegistryError.missing }
        return names
    }
}
