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

    init(directory: URL?) {
        self.directory = directory
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
            try JSONEncoder().encode(marker).write(to: url("generation.json"), options: .atomic)
            if value.isEmpty {
                if FileManager.default.fileExists(atPath: url("override.json").path) {
                    try FileManager.default.removeItem(at: url("override.json"))
                }
            } else {
                let envelope = Envelope(version: 1, generation: next, override: value, invalidReason: reason?.rawValue)
                try JSONEncoder().encode(envelope).write(to: url("override.json"), options: .atomic)
            }
            return Snapshot(generation: next, hasBeenConfigured: true, override: value, invalidReason: reason)
        }
    }

    private func read() throws -> Snapshot {
        let markerURL = try url("generation.json")
        let envelopeURL = try url("override.json")
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            guard !FileManager.default.fileExists(atPath: envelopeURL.path) else { throw Failure.corrupt }
            return .none
        }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        guard marker.version == 1 else { throw Failure.corrupt }
        guard FileManager.default.fileExists(atPath: envelopeURL.path) else {
            guard !marker.hasOverride else { throw Failure.corrupt }
            return Snapshot(generation: marker.generation, hasBeenConfigured: true, override: .none, invalidReason: nil)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: envelopeURL))
        guard marker.hasOverride, envelope.version == 1, envelope.generation == marker.generation else {
            throw Failure.corrupt
        }
        return Snapshot(generation: marker.generation, hasBeenConfigured: true, override: envelope.override,
                        invalidReason: envelope.invalidReason.flatMap(CaptureParameterFailure.init(rawValue:)))
    }

    private func url(_ name: String) throws -> URL {
        guard let directory else { throw Failure.unavailable }
        return directory.appendingPathComponent(name)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        guard let directory else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(descriptor, LOCK_UN) }
        do { return try operation() } catch let failure as Failure { throw failure } catch { throw Failure.unavailable }
    }
}
#endif
