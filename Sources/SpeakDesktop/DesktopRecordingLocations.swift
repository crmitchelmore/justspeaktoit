import Foundation

public enum DesktopRecordingLocationError: Error, LocalizedError, Sendable {
    case unregistered, foreignRegistration, duplicateIdentity, invalidReference, changedLocation, mutationUnavailable

    public var errorDescription: String? {
        switch self {
        case .unregistered: return "Recording audio has no verified local location registration."
        case .foreignRegistration: return "The recording location belongs to another local History store."
        case .duplicateIdentity: return "A recording or location identity is already registered; nothing was replaced."
        case .invalidReference: return "Recording audio has invalid or foreign local provenance."
        case .changedLocation: return "A registered recording directory or audio file was replaced."
        case .mutationUnavailable:
            return "External recording audio is retained: an owned repair/deletion capability is not implemented."
        }
    }
}

/// Typed causes are available for inspection; display text never includes their paths or values.
public struct DesktopRecordingLocationCleanupFailure: LocalizedError, CustomStringConvertible, Sendable {
    public let primaryError: Error
    public let cleanupError: Error

    public var errorDescription: String? { description }

    public var description: String {
        "Recording audio allocation failed, and unpublished capture cleanup could not be completed."
    }
}

/// Descriptive metadata only. Decoding this value never authorizes filesystem access.
public struct DesktopRecordingAudioReference: Codable, Equatable, Sendable {
    public let locationID: UUID
    public let relativePath: String
    var sourceKey: String { "\(locationID.uuidString)/\(relativePath)" }

    init(locationID: UUID, relativePath: String) {
        self.locationID = locationID
        self.relativePath = relativePath
    }
}

/// Trusted host adapter boundary, like DesktopOwnedCaptureFile.Factory, not an import codec.
/// Implementations must verify private local persistence before returning sealed registrations,
/// and append immutable identities exclusively. Overwriting a registry file is not this contract.
/// No production persistence adapter is supplied; an injected implementation is not host restart support.
public protocol DesktopRecordingLocationPersistence: Sendable {
    func loadVerified() throws -> DesktopRecordingLocationState
    func appendRegistration(_ registration: DesktopRecordingLocationRegistration) throws
    func appendRecording(_ recording: DesktopRecordingLocationOwnership) throws
}

public struct DesktopRecordingLocationState: Sendable {
    let registrations: [DesktopRecordingLocationRegistration]
    let recordings: [DesktopRecordingLocationOwnership]

    public init(
        verifiedRegistrations: [DesktopRecordingLocationRegistration] = [],
        verifiedRecordings: [DesktopRecordingLocationOwnership] = []
    ) {
        registrations = verifiedRegistrations
        recordings = verifiedRecordings
    }
}

/// Not Codable: imported paths/profile values cannot manufacture a local authorization.
public struct DesktopRecordingLocationRegistration: Sendable {
    public let id: UUID
    public let root: URL
    let history: URL
    let historyIdentity: DesktopRecordingLocationIdentity
    let rootIdentity: DesktopRecordingLocationIdentity
}

/// Minted only after exclusive held capture creation, never from History/import metadata.
public struct DesktopRecordingLocationOwnership: Sendable {
    public let recordingID: UUID
    public let reference: DesktopRecordingAudioReference
    let directoryIdentity: DesktopRecordingLocationIdentity
    let fileIdentity: DesktopRecordingLocationIdentity
}

struct DesktopRecordingLocationIdentity: Equatable, Sendable {
    let device: UInt64
    let file: UInt64

    init(_ identity: DesktopRecordingAudioSnapshot.Identity) throws {
        try DesktopOwnedAppDataFileReader.requireStrictIdentity(identity)
        guard let device = identity.device, let file = identity.file else {
            throw DesktopOwnedAppDataFileReadError.insufficientIdentity
        }
        self.device = device
        self.file = file
    }

    static func directory(_ url: URL) throws -> Self {
        let chain = try DesktopOwnedAppDataFileReader.directoryChain(
            DesktopOwnedAppDataFileReader.location(".recording-location-probe", root: url),
            checkCancellation: { try Task.checkCancellation() }
        )
        guard let identity = chain.first?.identity else {
            throw DesktopOwnedAppDataFileReadError.unsafeDirectory
        }
        return Self(device: identity.device, file: identity.file)
    }

    private init(device: UInt64, file: UInt64) {
        self.device = device
        self.file = file
    }
}

/// Append-only local provenance. All filesystem evidence here is read evidence, never mutation/CAS authority.
/// Synchronous I/O belongs on a separately owned cancellable worker when a host integrates this policy.
public struct DesktopRecordingLocations: Sendable {
    public struct Capture: Sendable {
        public let file: DesktopOwnedCaptureFile
        public let recordingID: UUID
        public let reference: DesktopRecordingAudioReference
    }

    let history: URL
    private let historyIdentity: DesktopRecordingLocationIdentity
    private let persistence: any DesktopRecordingLocationPersistence
    private var registrations: [UUID: DesktopRecordingLocationRegistration] = [:]
    var recordings: [UUID: DesktopRecordingLocationOwnership] = [:]

    public init(historyDirectory: URL, persistence: any DesktopRecordingLocationPersistence) throws {
        try Self.validateRootURL(historyDirectory)
        history = historyDirectory.standardizedFileURL
        historyIdentity = try .directory(history)
        self.persistence = persistence
        let state = try persistence.loadVerified()
        for registration in state.registrations {
            guard registrations[registration.id] == nil else { throw DesktopRecordingLocationError.duplicateIdentity }
            try validate(registration)
            registrations[registration.id] = registration
        }
        for recording in state.recordings {
            guard recordings[recording.recordingID] == nil else {
                throw DesktopRecordingLocationError.duplicateIdentity
            }
            _ = try location(recording.reference, recordingID: recording.recordingID)
            recordings[recording.recordingID] = recording
        }
    }

    public mutating func authorizeLocallySelectedRoot(_ root: URL, id: UUID = UUID()) throws -> UUID {
        try Task.checkCancellation()
        guard registrations[id] == nil else { throw DesktopRecordingLocationError.duplicateIdentity }
        try Self.validateRootURL(root)
        let registration = DesktopRecordingLocationRegistration(
            id: id, root: root.standardizedFileURL, history: history, historyIdentity: historyIdentity,
            rootIdentity: try .directory(root)
        )
        try validate(registration)
        try persistence.appendRegistration(registration)
        try Task.checkCancellation()
        try validate(registration)
        registrations[id] = registration
        return id
    }

    public mutating func createCapture(
        at locationID: UUID, recordingID: UUID = UUID(), using factory: DesktopOwnedCaptureFile.Factory = .native,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Capture {
        try checkCancellation()
        guard recordings[recordingID] == nil else { throw DesktopRecordingLocationError.duplicateIdentity }
        guard let registration = registrations[locationID] else { throw DesktopRecordingLocationError.unregistered }
        try validate(registration)
        let directoryID = UUID()
        let reference = DesktopRecordingAudioReference(
            locationID: locationID, relativePath: "\(directoryID.uuidString)/\(recordingID.uuidString).wav"
        )
        let file = try DesktopOwnedCaptureFile.create(
            in: registration.root, directoryID: directoryID, recordingID: recordingID, using: factory,
            checkCancellation: checkCancellation
        )
        do {
            let location = try location(reference, recordingID: recordingID)
            guard file.url.standardizedFileURL == location.file.standardizedFileURL else {
                throw DesktopRecordingLocationError.invalidReference
            }
            try file.synchronize()
            guard let identity = try DesktopOwnedAppDataFileReader.strictSourceIdentity(location.file) else {
                throw DesktopRecordingLocationError.changedLocation
            }
            let ownership = DesktopRecordingLocationOwnership(
                recordingID: recordingID, reference: reference,
                directoryIdentity: try .directory(location.parent), fileIdentity: try .init(identity)
            )
            try checkCancellation()
            try validate(registration)
            try persistence.appendRecording(ownership)
            try checkCancellation()
            try file.synchronize()
            try validate(registration)
            recordings[recordingID] = ownership
            return Capture(file: file, recordingID: recordingID, reference: reference)
        } catch {
            let original = error
            do { try file.discard() } catch {
                throw DesktopRecordingLocationCleanupFailure(
                    primaryError: original, cleanupError: error
                )
            }
            throw original
        }
    }

    func validateHistory(_ directory: URL) throws {
        guard directory.standardizedFileURL == history,
              try DesktopRecordingLocationIdentity.directory(directory) == historyIdentity else {
            throw DesktopRecordingLocationError.foreignRegistration
        }
    }

    func protectsAudioDestination(_ target: URL) -> Bool {
        recordings.values.contains { ownership in
            guard let registration = registrations[ownership.reference.locationID] else { return false }
            let path = registration.root.appendingPathComponent(ownership.reference.relativePath)
                .resolvingSymlinksInPath().standardizedFileURL.path
            return path.caseInsensitiveCompare(target.path) == .orderedSame
        }
    }

    func resolve(_ record: DesktopRecordingStore.Record) throws -> URL {
        guard let reference = record.localAudio, !record.isSyncedCopy,
              let ownership = recordings[record.id], ownership.reference == reference else {
            throw DesktopRecordingLocationError.invalidReference
        }
        let location = try location(reference, recordingID: record.id)
        guard record.audioFilename == location.file.lastPathComponent,
              try DesktopRecordingLocationIdentity.directory(location.parent) == ownership.directoryIdentity else {
            throw DesktopRecordingLocationError.changedLocation
        }
        guard let identity = try DesktopOwnedAppDataFileReader.strictSourceIdentity(location.file) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard try DesktopRecordingLocationIdentity(identity) == ownership.fileIdentity else {
            throw DesktopRecordingLocationError.changedLocation
        }
        return location.file
    }

    func read(_ record: DesktopRecordingStore.Record, maximumBytes: UInt64) throws -> Data {
        _ = try resolve(record)
        guard let reference = record.localAudio else { throw DesktopRecordingLocationError.invalidReference }
        let location = try location(reference, recordingID: record.id)
        let snapshot = try DesktopOwnedAppDataFileReader.readStrict(
            reference.relativePath, appDirectory: location.root, maximumBytes: maximumBytes
        )
        _ = try resolve(record)
        guard let data = snapshot.data else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    private func location(
        _ reference: DesktopRecordingAudioReference, recordingID: UUID
    ) throws -> DesktopOwnedAppDataFileReader.Location {
        guard let registration = registrations[reference.locationID] else {
            throw DesktopRecordingLocationError.unregistered
        }
        try validate(registration)
        let location = try DesktopOwnedAppDataFileReader.location(reference.relativePath, root: registration.root)
        let components = reference.relativePath.split(separator: "/")
        guard components.count == 2, UUID(uuidString: String(components[0])) != nil,
              components[1] == "\(recordingID.uuidString).wav" else {
            throw DesktopRecordingLocationError.invalidReference
        }
        return location
    }

    private func validate(_ registration: DesktopRecordingLocationRegistration) throws {
        try validateHistory(registration.history)
        guard registration.historyIdentity == historyIdentity else {
            throw DesktopRecordingLocationError.foreignRegistration
        }
        try Self.validateRootURL(registration.root)
        guard try DesktopRecordingLocationIdentity.directory(registration.root) == registration.rootIdentity else {
            throw DesktopRecordingLocationError.changedLocation
        }
    }

    private static func validateRootURL(_ root: URL) throws {
        guard root.isFileURL, root.host?.isEmpty != false, root.query == nil, root.fragment == nil,
              !root.path.utf8.contains(0) else { throw DesktopOwnedAppDataFileReadError.invalidLocation }
    }
}
