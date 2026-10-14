import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class RecordingLocationMemoryPersistence: DesktopRecordingLocationPersistence, @unchecked Sendable {
    enum Failure: Error { case registration, recording }
    private let lock = NSLock()
    private var registrations: [DesktopRecordingLocationRegistration] = []
    private var recordings: [DesktopRecordingLocationOwnership] = []
    var failure: Failure?
    var recordingError: Error?
    var overrideState: DesktopRecordingLocationState?

    func loadVerified() throws -> DesktopRecordingLocationState {
        lock.lock()
        defer { lock.unlock() }
        if let overrideState { return overrideState }
        return .init(verifiedRegistrations: registrations, verifiedRecordings: recordings)
    }

    func appendRegistration(_ registration: DesktopRecordingLocationRegistration) throws {
        lock.lock()
        defer { lock.unlock() }
        if case .registration = failure { throw Failure.registration }
        guard !registrations.contains(where: { $0.id == registration.id }) else {
            throw DesktopRecordingLocationError.duplicateIdentity
        }
        registrations.append(registration)
    }

    func appendRecording(_ recording: DesktopRecordingLocationOwnership) throws {
        lock.lock()
        defer { lock.unlock() }
        if let recordingError { throw recordingError }
        if case .recording = failure { throw Failure.recording }
        guard !recordings.contains(where: { $0.recordingID == recording.recordingID }) else {
            throw DesktopRecordingLocationError.duplicateIdentity
        }
        recordings.append(recording)
    }
}

enum RecordingCleanupInjectedError: LocalizedError, Equatable {
    case append(String), remove(String)

    var errorDescription: String? {
        switch self {
        case let .append(value), let .remove(value): return value
        }
    }
}

/// Portable failure fixture, not a qualified native creation adapter.
final class RecordingCleanupWriter: DesktopOwnedCaptureWriter, @unchecked Sendable {
    private(set) var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    private var handle: FileHandle?
    private(set) var creations = 0
    private(set) var removals = 0
    private(set) var closes = 0
    let bytes = Data([27, 91, 42])

    var factory: DesktopOwnedCaptureFile.Factory {
        .init { [self] root, directoryID, recordingID in
            creations += 1
            let directory = root.appendingPathComponent(directoryID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            url = directory.appendingPathComponent(recordingID.uuidString + ".wav")
            try bytes.write(to: url, options: .withoutOverwriting)
            handle = try FileHandle(forWritingTo: url)
            return self
        }
    }

    func write(_ data: Data) throws { try heldHandle().write(contentsOf: data) }
    func seek(toOffset offset: UInt64) throws { try heldHandle().seek(toOffset: offset) }
    func synchronize() throws { try heldHandle().synchronize() }
    func validateLocation() throws { _ = try heldHandle() }

    func removeUnpublished() throws {
        removals += 1
        throw RecordingCleanupInjectedError.remove(url.path)
    }

    func close() throws {
        closes += 1
        try heldHandle().close()
        handle = nil
    }

    private func heldHandle() throws -> FileHandle {
        guard let handle else { throw DesktopOwnedCaptureError.closed }
        return handle
    }
}

struct RecordingLocationFixture {
    let root: URL
    let history: URL
    let first: URL
    let second: URL
    let memory = RecordingLocationMemoryPersistence()

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/recording-location-" + UUID().uuidString, isDirectory: true)
        history = root.appendingPathComponent("History", isDirectory: true)
        first = root.appendingPathComponent("Audio A", isDirectory: true)
        second = root.appendingPathComponent("Audio B", isDirectory: true)
        for directory in [history, first, second] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func store() throws -> DesktopRecordingStore {
        try DesktopRecordingStore(
            directory: history,
            audioLocations: DesktopRecordingLocations(historyDirectory: history, persistence: memory)
        )
    }

    func capture(
        _ store: DesktopRecordingStore, location: UUID, id: UUID = UUID()
    ) async throws -> DesktopRecordingStore.Record {
        #if !os(Linux)
        throw XCTSkip("Uses the qualified Linux held capture factory, not a Windows/Darwin success fallback.")
        #else
        let capture = try await store.createLocallyAuthorizedCapture(at: location, recordingID: id)
        let file = try PCMRecordingFile(ownedFile: capture.file, sampleRate: 16_000)
        try file.append(Data([1, 2, 3, 4]))
        _ = try file.finish()
        var record = DesktopRecordingStore.Record(capture: capture, modelIdentifier: "fixture")
        record.processedText = "Synthetic transcript"
        try await store.save(record)
        return record
        #endif
    }

    func clean() throws { try FileManager.default.removeItem(at: root) }

    static let digests = LocalModelDigestProvider(name: "Constant fixture digest, not a hash implementation") {
        RecordingLocationFixtureHasher()
    }
}

private final class RecordingLocationFixtureHasher: LocalModelSHA256Hasher {
    func update(_: UnsafeRawBufferPointer) throws {}
    func finish() throws -> String { String(repeating: "a", count: 64) }
}
