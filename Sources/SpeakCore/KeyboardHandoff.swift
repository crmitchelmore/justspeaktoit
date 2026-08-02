import Foundation

/// The only App Group payload used by the custom keyboard handoff.
///
/// Audio, API keys, surrounding text, and intermediate transcripts are never
/// written here. The App Group copy of the final transcript exists only until
/// the matching keyboard consumes it or the short result timeout expires.
/// History persistence happens separately inside the containing app.
public struct KeyboardHandoffRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Phase: String, Codable, Equatable, Hashable, Sendable {
        case requested
        case recording
        case transcribing
        case completed
        case cancelled
        case failed
    }

    public enum FailureCode: String, Codable, Equatable, Sendable {
        case fullAccessRequired
        case appUnavailable
        case recordingUnavailable
        case noSpeech
        case timedOut
        case invalidRequest
        case unknown
    }

    public let schemaVersion: Int
    public let requestID: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let expiresAt: Date
    public let phase: Phase
    public let transcript: String?
    public let failureCode: FailureCode?

    public init(
        schemaVersion: Int = Self.schemaVersion,
        requestID: UUID,
        createdAt: Date,
        updatedAt: Date,
        expiresAt: Date,
        phase: Phase,
        transcript: String? = nil,
        failureCode: FailureCode? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.phase = phase
        self.transcript = transcript
        self.failureCode = failureCode
    }
}

public struct KeyboardExtensionObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let lastSeenAt: Date
    public let hadFullAccess: Bool

    public init(
        schemaVersion: Int = KeyboardHandoffRecord.schemaVersion,
        lastSeenAt: Date,
        hadFullAccess: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.lastSeenAt = lastSeenAt
        self.hadFullAccess = hadFullAccess
    }
}

public enum KeyboardHandoffStoreError: Error, Equatable {
    case unavailable
    case noActiveRequest
    case mismatchedRequest
    case invalidTransition
    case invalidTranscript
}

/// A deliberately small, extension-safe store backed by the shared App Group.
///
/// The entire handoff is a single encoded value so readers never combine fields
/// from different requests. Each mutation validates the nonce and transition.
public final class KeyboardHandoffStore {
    public static let appGroupIdentifier = "group.com.justspeaktoit.ios"
    public static let shared = KeyboardHandoffStore()

    public static let requestLifetime: TimeInterval = 3 * 60
    public static let transcriptionLifetime: TimeInterval = 90
    public static let resultLifetime: TimeInterval = 60

    private static let recordKey = "keyboardHandoff.record.v1"
    private static let observationKey = "keyboardHandoff.extensionObservation.v1"

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: Self.appGroupIdentifier))
    }

    /// Injectable for deterministic tests. Passing `nil` models a missing or
    /// inaccessible App Group.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public var isAvailable: Bool {
        defaults != nil
    }

    @discardableResult
    public func createRequest(
        id: UUID = UUID(),
        now: Date = Date(),
        lifetime: TimeInterval = requestLifetime
    ) throws -> KeyboardHandoffRecord {
        guard defaults != nil else { throw KeyboardHandoffStoreError.unavailable }
        let record = KeyboardHandoffRecord(
            requestID: id,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(lifetime),
            phase: .requested
        )
        try write(record)
        return record
    }

    public func record(matching requestID: UUID, now: Date = Date()) -> KeyboardHandoffRecord? {
        lock.withLock {
            guard let record = readUnlocked(), record.requestID == requestID else { return nil }
            return normalizeExpiryUnlocked(record, now: now)
        }
    }

    public func activeRecord(now: Date = Date()) -> KeyboardHandoffRecord? {
        lock.withLock {
            guard let record = readUnlocked() else { return nil }
            return normalizeExpiryUnlocked(record, now: now)
        }
    }

    @discardableResult
    public func markRecording(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        try transition(
            requestID: requestID,
            allowedFrom: [.requested],
            to: .recording,
            now: now,
            lifetime: Self.requestLifetime
        )
    }

    @discardableResult
    public func markTranscribing(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        try transition(
            requestID: requestID,
            allowedFrom: [.recording],
            to: .transcribing,
            now: now,
            lifetime: Self.transcriptionLifetime
        )
    }

    @discardableResult
    public func complete(
        requestID: UUID,
        transcript: String,
        now: Date = Date()
    ) throws -> KeyboardHandoffRecord {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyboardHandoffStoreError.invalidTranscript }
        return try transition(
            requestID: requestID,
            allowedFrom: [.transcribing],
            to: .completed,
            transcript: trimmed,
            now: now,
            lifetime: Self.resultLifetime
        )
    }

    @discardableResult
    public func cancel(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        try transition(
            requestID: requestID,
            allowedFrom: [.requested, .recording, .transcribing],
            to: .cancelled,
            now: now,
            lifetime: Self.resultLifetime
        )
    }

    @discardableResult
    public func fail(
        requestID: UUID,
        code: KeyboardHandoffRecord.FailureCode,
        now: Date = Date()
    ) throws -> KeyboardHandoffRecord {
        try transition(
            requestID: requestID,
            allowedFrom: [.requested, .recording, .transcribing],
            to: .failed,
            failureCode: code,
            now: now,
            lifetime: Self.resultLifetime
        )
    }

    /// Returns and then promptly removes only the matching, unexpired result.
    public func consumeResult(requestID: UUID, now: Date = Date()) -> String? {
        lock.withLock {
            guard let stored = readUnlocked(),
                  stored.requestID == requestID,
                  let record = normalizeExpiryUnlocked(stored, now: now),
                  record.phase == .completed,
                  let transcript = record.transcript,
                  !transcript.isEmpty else {
                return nil
            }
            defaults?.removeObject(forKey: Self.recordKey)
            defaults?.synchronize()
            return transcript
        }
    }

    /// Removes only the caller's request, so an old keyboard cannot clear a
    /// newer request after process suspension.
    public func clear(requestID: UUID) {
        lock.withLock {
            guard readUnlocked()?.requestID == requestID else { return }
            defaults?.removeObject(forKey: Self.recordKey)
            defaults?.synchronize()
        }
    }

    public func recordExtensionObservation(hasFullAccess: Bool, now: Date = Date()) {
        guard let defaults else { return }
        let observation = KeyboardExtensionObservation(lastSeenAt: now, hadFullAccess: hasFullAccess)
        guard let data = try? encoder.encode(observation) else { return }
        defaults.set(data, forKey: Self.observationKey)
        defaults.synchronize()
    }

    public func extensionObservation() -> KeyboardExtensionObservation? {
        guard let data = defaults?.data(forKey: Self.observationKey) else { return nil }
        return try? decoder.decode(KeyboardExtensionObservation.self, from: data)
    }

    private func transition(
        requestID: UUID,
        allowedFrom: Set<KeyboardHandoffRecord.Phase>,
        to phase: KeyboardHandoffRecord.Phase,
        transcript: String? = nil,
        failureCode: KeyboardHandoffRecord.FailureCode? = nil,
        now: Date,
        lifetime: TimeInterval
    ) throws -> KeyboardHandoffRecord {
        try lock.withLock {
            guard defaults != nil else { throw KeyboardHandoffStoreError.unavailable }
            guard let stored = readUnlocked() else { throw KeyboardHandoffStoreError.noActiveRequest }
            guard stored.requestID == requestID else { throw KeyboardHandoffStoreError.mismatchedRequest }
            guard let current = normalizeExpiryUnlocked(stored, now: now),
                  allowedFrom.contains(current.phase) else {
                throw KeyboardHandoffStoreError.invalidTransition
            }

            let updated = KeyboardHandoffRecord(
                requestID: current.requestID,
                createdAt: current.createdAt,
                updatedAt: now,
                expiresAt: now.addingTimeInterval(lifetime),
                phase: phase,
                transcript: transcript,
                failureCode: failureCode
            )
            try writeUnlocked(updated)
            return updated
        }
    }

    private func write(_ record: KeyboardHandoffRecord) throws {
        try lock.withLock {
            try writeUnlocked(record)
        }
    }

    private func writeUnlocked(_ record: KeyboardHandoffRecord) throws {
        guard let defaults else { throw KeyboardHandoffStoreError.unavailable }
        defaults.set(try encoder.encode(record), forKey: Self.recordKey)
        defaults.synchronize()
    }

    private func readUnlocked() -> KeyboardHandoffRecord? {
        guard let data = defaults?.data(forKey: Self.recordKey),
              let record = try? decoder.decode(KeyboardHandoffRecord.self, from: data),
              record.schemaVersion == KeyboardHandoffRecord.schemaVersion else {
            return nil
        }
        return record
    }

    private func normalizeExpiryUnlocked(
        _ record: KeyboardHandoffRecord,
        now: Date
    ) -> KeyboardHandoffRecord? {
        guard record.expiresAt <= now else { return record }

        if record.phase == .cancelled || record.phase == .failed {
            defaults?.removeObject(forKey: Self.recordKey)
            defaults?.synchronize()
            return nil
        }

        let timedOut = KeyboardHandoffRecord(
            requestID: record.requestID,
            createdAt: record.createdAt,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(Self.resultLifetime),
            phase: .failed,
            failureCode: .timedOut
        )
        try? writeUnlocked(timedOut)
        return timedOut
    }
}

public enum KeyboardLaunchPolicy {
    public enum BlockReason: Equatable {
        case fullAccessRequired
        case sharedContainerUnavailable
    }

    public static func blockReason(
        hasFullAccess: Bool,
        sharedContainerAvailable: Bool
    ) -> BlockReason? {
        if !hasFullAccess {
            return .fullAccessRequired
        }
        if !sharedContainerAvailable {
            return .sharedContainerUnavailable
        }
        return nil
    }

    /// A manually opened containing app should resume only a fresh request
    /// that has not started recording yet.
    public static func pendingCaptureRequestID(
        from record: KeyboardHandoffRecord?
    ) -> UUID? {
        guard let record, record.phase == .requested else { return nil }
        return record.requestID
    }
}

public struct KeyboardHandoffConsumer {
    private let store: KeyboardHandoffStore

    public init(store: KeyboardHandoffStore = .shared) {
        self.store = store
    }

    /// Inserts only a matching result and clears it immediately afterwards.
    @discardableResult
    public func insertReadyResult(
        requestID: UUID,
        now: Date = Date(),
        insert: (String) -> Void
    ) -> Bool {
        guard let transcript = store.consumeResult(requestID: requestID, now: now) else {
            return false
        }
        insert(transcript)
        return true
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
