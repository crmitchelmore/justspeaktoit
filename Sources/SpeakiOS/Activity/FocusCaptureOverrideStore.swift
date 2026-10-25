#if os(iOS)
import Darwin
import Foundation
import SpeakCore

/// One App Group writer path for native perform, reset and generation-checked reconciliation.
/// A nonblocking interprocess lock fails safely; no native await occurs while it is held.
final class FocusCaptureOverrideStore {
    enum Failure: Error, LocalizedError {
        case unavailable
        case busy
        case corrupt
        case nativeLookup

        var errorDescription: String? {
            "The Focus capture override could not be verified. Open Just Speak settings to review or reset it."
        }
    }

    struct Snapshot: Equatable, Sendable {
        let generation: UUID?
        let hasBeenConfigured: Bool
        let override: FocusCaptureOverride
        let invalidReason: CaptureParameterFailure?

        static let none = Snapshot(generation: nil, hasBeenConfigured: false, override: .none, invalidReason: nil)
    }

    private struct Marker: Codable {
        let version: Int
        let generation: UUID
        let hasOverride: Bool
    }

    private struct Envelope: Codable {
        let version: Int
        let generation: UUID
        let override: FocusCaptureOverride
        let invalidReason: String?
    }

    private let directory: URL?
    private let readData: (URL) throws -> Data

    init(directory: URL?, readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.directory = directory
        self.readData = readData
    }

    static func live() -> FocusCaptureOverrideStore {
        Self(directory: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardHandoffStore.appGroupIdentifier
        )?.appendingPathComponent("FocusCapture", isDirectory: true))
    }

    func snapshot() throws -> Snapshot {
        try withLock { try read() }
    }

    @discardableResult
    func write(
        _ value: FocusCaptureOverride, ifGeneration generation: UUID? = nil, compare: Bool = false
    ) throws -> Snapshot {
        try withLock {
            if compare {
                let existing = try read()
                if existing.generation != generation { return existing }
            }
            let next = UUID()
            let reason: CaptureParameterFailure?
            do {
                _ = try CaptureParameterResolution.resolve(
                    destinationID: value.destinationID, language: value.languageIdentifier,
                    model: value.modelID, vocabulary: CaptureModelSupport.vocabulary
                )
                reason = nil
            } catch let failure as CaptureParameterFailure {
                reason = failure
            }
            // A crash between these atomic writes leaves a mismatch that read() refuses.
            let marker = Marker(version: 1, generation: next, hasOverride: !value.isEmpty)
            try JSONEncoder().encode(marker).write(
                to: url("generation.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            if value.isEmpty {
                if unlink(try url("override.json").path) != 0 && errno != ENOENT { throw Failure.unavailable }
            } else {
                let envelope = Envelope(version: 1, generation: next, override: value, invalidReason: reason?.rawValue)
                try JSONEncoder().encode(envelope).write(
                    to: url("override.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
            return Snapshot(generation: next, hasBeenConfigured: true, override: value, invalidReason: reason)
        }
    }

    private func read() throws -> Snapshot {
        guard let markerData = try readOptional("generation.json") else {
            guard try readOptional("override.json") == nil else { throw Failure.corrupt }
            return .none
        }
        let marker = try JSONDecoder().decode(Marker.self, from: markerData)
        guard marker.version == 1 else { throw Failure.corrupt }
        guard let envelopeData = try readOptional("override.json") else {
            guard !marker.hasOverride else { throw Failure.corrupt }
            return Snapshot(generation: marker.generation, hasBeenConfigured: true, override: .none, invalidReason: nil)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: envelopeData)
        guard marker.hasOverride, envelope.version == 1, envelope.generation == marker.generation else {
            throw Failure.corrupt
        }
        return Snapshot(generation: marker.generation, hasBeenConfigured: true, override: envelope.override,
                        invalidReason: envelope.invalidReason.flatMap(CaptureParameterFailure.init(rawValue:)))
    }

    private func readOptional(_ name: String) throws -> Data? {
        let path = try url(name)
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0 else {
            guard errno == ENOENT else { throw Failure.unavailable }
            return nil
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw Failure.corrupt }
        return try readData(path)
    }

    private func url(_ name: String) throws -> URL {
        guard let directory else { throw Failure.unavailable }
        return directory.appendingPathComponent(name)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        guard let directory else { throw Failure.unavailable }
        do {
            let protection: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: protection)
            try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
            let descriptor = open(directory.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR,
                                  S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw Failure.unavailable }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
            defer { flock(descriptor, LOCK_UN) }
            return try operation()
        } catch let failure as Failure { throw failure } catch { throw Failure.unavailable }

    }
}
#endif
