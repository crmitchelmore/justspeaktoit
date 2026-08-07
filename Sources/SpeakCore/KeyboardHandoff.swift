import Foundation

/// A deliberately small, extension-safe store backed by the shared App Group.
///
/// The entire handoff is a single encoded value so readers never combine fields
/// from different requests. Each mutation validates the nonce and transition.
/// `@unchecked` only because `UserDefaults` lacks a Sendable annotation in the
/// SDK: all stored properties are immutable references, `UserDefaults` is
/// documented thread-safe, and the `NSLock` serializes every
/// read-modify-write.
public final class KeyboardHandoffStore: @unchecked Sendable {
    public static let appGroupIdentifier = "group.com.justspeaktoit.ios"
    public static let shared = KeyboardHandoffStore()

    public static let requestLifetime: TimeInterval = 3 * 60
    public static let transcriptionLifetime: TimeInterval = 90
    public static let resultLifetime: TimeInterval = 60

    private static let recordKey = "keyboardHandoff.record.v2"
    private static let observationKey = "keyboardHandoff.extensionObservation.v2"

    private let defaults: UserDefaults?
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
        targetDocumentIdentifier: UUID? = nil,
        now: Date = Date(),
        lifetime: TimeInterval = requestLifetime
    ) throws -> KeyboardHandoffRecord {
        guard defaults != nil else { throw KeyboardHandoffStoreError.unavailable }
        let record = KeyboardHandoffRecord(
            requestID: id,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(lifetime),
            phase: .requested,
            targetDocumentIdentifier: targetDocumentIdentifier
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
            allowedFrom: [.recording, .finishRequested],
            to: .transcribing,
            now: now,
            lifetime: Self.transcriptionLifetime
        )
    }

    @discardableResult
    public func requestFinish(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        try transition(
            requestID: requestID,
            allowedFrom: [.recording],
            to: .finishRequested,
            now: now,
            lifetime: Self.transcriptionLifetime
        )
    }

    /// Publishes only the current request's live text. It is replaced on each
    /// update, never appended, and is removed when the request ends.
    @discardableResult
    public func updateInterim(
        requestID: UUID,
        transcript: String,
        now: Date = Date()
    ) throws -> KeyboardHandoffRecord {
        try lock.withLock {
            guard defaults != nil else { throw KeyboardHandoffStoreError.unavailable }
            guard let stored = readUnlocked() else { throw KeyboardHandoffStoreError.noActiveRequest }
            guard stored.requestID == requestID else { throw KeyboardHandoffStoreError.mismatchedRequest }
            guard let current = normalizeExpiryUnlocked(stored, now: now),
                  current.phase == .recording else {
                throw KeyboardHandoffStoreError.invalidTransition
            }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = KeyboardHandoffRecord(
                requestID: current.requestID,
                createdAt: current.createdAt,
                updatedAt: now,
                expiresAt: now.addingTimeInterval(Self.requestLifetime),
                phase: current.phase,
                targetDocumentIdentifier: current.targetDocumentIdentifier,
                interimTranscript: trimmed.isEmpty ? nil : trimmed
            )
            try writeUnlocked(updated)
            return updated
        }
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
            allowedFrom: [.requested, .recording, .finishRequested, .transcribing],
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
            allowedFrom: [.requested, .recording, .finishRequested, .transcribing],
            to: .failed,
            failureCode: code,
            now: now,
            lifetime: Self.resultLifetime
        )
    }

    /// Returns and then promptly removes only the matching, unexpired result.
    public func consumeResult(
        requestID: UUID,
        documentIdentifier: UUID? = nil,
        now: Date = Date()
    ) -> String? {
        lock.withLock {
            guard let stored = readUnlocked(),
                  stored.requestID == requestID,
                  let record = normalizeExpiryUnlocked(stored, now: now),
                  record.phase == .completed,
                  record.targetDocumentIdentifier == nil
                    || record.targetDocumentIdentifier == documentIdentifier,
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
        guard let data = try? JSONEncoder().encode(observation) else { return }
        defaults.set(data, forKey: Self.observationKey)
        defaults.synchronize()
    }

    public func extensionObservation() -> KeyboardExtensionObservation? {
        guard let data = defaults?.data(forKey: Self.observationKey) else { return nil }
        return try? JSONDecoder().decode(KeyboardExtensionObservation.self, from: data)
    }
}

private extension KeyboardHandoffStore {
    func transition(
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
                targetDocumentIdentifier: current.targetDocumentIdentifier,
                interimTranscript: phase == .recording || phase == .finishRequested || phase == .transcribing
                    ? current.interimTranscript
                    : nil,
                transcript: transcript,
                failureCode: failureCode
            )
            try writeUnlocked(updated)
            return updated
        }
    }

    func write(_ record: KeyboardHandoffRecord) throws {
        try lock.withLock {
            try writeUnlocked(record)
        }
    }

    func writeUnlocked(_ record: KeyboardHandoffRecord) throws {
        guard let defaults else { throw KeyboardHandoffStoreError.unavailable }
        defaults.set(try JSONEncoder().encode(record), forKey: Self.recordKey)
        defaults.synchronize()
    }

    func readUnlocked() -> KeyboardHandoffRecord? {
        guard let data = defaults?.data(forKey: Self.recordKey),
              let record = try? JSONDecoder().decode(KeyboardHandoffRecord.self, from: data),
              record.schemaVersion == KeyboardHandoffRecord.schemaVersion else {
            return nil
        }
        return record
    }

    func normalizeExpiryUnlocked(
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
            targetDocumentIdentifier: record.targetDocumentIdentifier,
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
        documentIdentifier: UUID? = nil,
        now: Date = Date(),
        insert: (String) -> Void
    ) -> Bool {
        guard let transcript = store.consumeResult(
            requestID: requestID,
            documentIdentifier: documentIdentifier,
            now: now
        ) else {
            return false
        }
        insert(transcript)
        return true
    }
}
