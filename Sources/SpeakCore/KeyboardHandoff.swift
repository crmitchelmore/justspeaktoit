import Foundation

/// Cross-process handoff store for keyboard dictation (issue #712).
///
/// App and keyboard extension are separate processes, so an in-process lock
/// cannot make whole-record read-modify-write safe: the app's interim update
/// could re-write a record the extension had just cancelled, resurrecting a
/// closed recording. The v4 layout removes every cross-process
/// read-modify-write by giving each key exactly one writing process:
///
/// | Key            | Writer            | Contents                            |
/// |----------------|-------------------|-------------------------------------|
/// | `intent.v4`    | keyboard extension| request identity + monotonic command|
/// | `status.v4`    | containing app    | app-side phase, transcript, failure |
/// | `interim.v4`   | containing app    | live transcript text only           |
///
/// Readers merge the keys into the familiar `KeyboardHandoffRecord`. Commands
/// travel in the extension's own key with a monotonic sequence, so no app
/// write can overwrite them; interim text lives apart from control state, so
/// a text update cannot regress a phase; expiry is derived at read time and
/// never written back. Every mutation validates the request identity, so a
/// suspended old process cannot affect a replacement request.
public final class KeyboardHandoffStore: @unchecked Sendable {
    public static let appGroupIdentifier = "group.com.justspeaktoit.ios"
    public static let shared = KeyboardHandoffStore()

    public static let requestLifetime: TimeInterval = 3 * 60
    public static let transcriptionLifetime: TimeInterval = 90
    public static let resultLifetime: TimeInterval = 60

    /// Which process this store instance is running in. Writes are routed to
    /// the process's own key so cross-process ownership is structural.
    public enum Role: Sendable {
        case containingApp
        case keyboardExtension

        public static var detected: Role {
            Bundle.main.bundleURL.pathExtension == "appex" ? .keyboardExtension : .containingApp
        }
    }

    static let intentKey = "keyboardHandoff.intent.v4"
    static let statusKey = "keyboardHandoff.status.v4"
    static let interimKey = "keyboardHandoff.interim.v4"
    static let legacyRecordKey = "keyboardHandoff.record.v3"
    static let observationKey = "keyboardHandoff.extensionObservation.v3"

    let defaults: UserDefaults?
    private let role: Role
    /// Serialises this process's own writes; cross-process safety comes from
    /// per-key ownership, not from this lock.
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: AppGroupAvailability.verifiedDefaults())
    }

    /// Injectable for deterministic tests. Passing `nil` models a missing or
    /// inaccessible App Group. Tests pass explicit roles to model the two
    /// processes as two independent store instances.
    public init(defaults: UserDefaults?, role: Role = .detected) {
        self.defaults = defaults
        self.role = role
    }

    public var isAvailable: Bool {
        defaults != nil
    }

    // MARK: - Extension-side intent

    @discardableResult
    public func createRequest(
        id: UUID = UUID(),
        targetDocumentIdentifier: UUID? = nil,
        profile: KeyboardDictationProfileOption? = nil,
        now: Date = Date(),
        lifetime: TimeInterval = requestLifetime
    ) throws -> KeyboardHandoffRecord {
        try lock.withLock {
            guard let defaults else { throw KeyboardHandoffStoreError.unavailable }
            let intent = IntentRecord(
                requestID: id,
                createdAt: now,
                expiresAt: now.addingTimeInterval(lifetime),
                targetDocumentIdentifier: targetDocumentIdentifier,
                profile: profile
            )
            // A new request owns the whole store: stale status/interim from a
            // previous request (and any pre-v4 record) are removed.
            defaults.set(try JSONEncoder().encode(intent), forKey: Self.intentKey)
            defaults.removeObject(forKey: Self.statusKey)
            defaults.removeObject(forKey: Self.interimKey)
            defaults.removeObject(forKey: Self.legacyRecordKey)
            defaults.synchronize()
            guard let record = mergedRecordUnlocked(now: now) else {
                throw KeyboardHandoffStoreError.unavailable
            }
            return record
        }
    }

    /// Requests finalisation via the extension-owned monotonic command
    /// channel, so no later app write can overwrite it.
    @discardableResult
    public func requestFinish(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        try issueCommand(.finish, requestID: requestID, allowedFrom: [.recording], now: now)
    }

    @discardableResult
    public func cancel(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        let allowed: Set<KeyboardHandoffRecord.Phase> = [
            .requested, .recording, .finishRequested, .transcribing
        ]
        switch role {
        case .keyboardExtension:
            return try issueCommand(.cancel, requestID: requestID, allowedFrom: allowed, now: now)
        case .containingApp:
            return try writeStatus(
                requestID: requestID,
                allowedFrom: allowed,
                phase: .cancelled,
                now: now,
                lifetime: Self.resultLifetime
            )
        }
    }

    // MARK: - App-side phase transitions

    @discardableResult
    public func markRecording(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        try writeStatus(
            requestID: requestID,
            allowedFrom: [.requested],
            phase: .recording,
            now: now,
            lifetime: Self.requestLifetime
        )
    }

    @discardableResult
    public func markTranscribing(requestID: UUID, now: Date = Date()) throws -> KeyboardHandoffRecord {
        try writeStatus(
            requestID: requestID,
            allowedFrom: [.recording, .finishRequested],
            phase: .transcribing,
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
        return try writeStatus(
            requestID: requestID,
            allowedFrom: [.transcribing],
            phase: .completed,
            transcript: trimmed,
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
        try writeStatus(
            requestID: requestID,
            allowedFrom: [.requested, .recording, .finishRequested, .transcribing],
            phase: .failed,
            failureCode: code,
            now: now,
            lifetime: Self.resultLifetime
        )
    }

    /// Publishes only the current request's live text, in a key of its own:
    /// an interim update can no longer touch — let alone regress — the
    /// control phase (issue #712). The app-owned status expiry is refreshed so
    /// a long dictation cannot time out mid-sentence.
    @discardableResult
    public func updateInterim(
        requestID: UUID,
        transcript: String,
        now: Date = Date()
    ) throws -> KeyboardHandoffRecord {
        try lock.withLock {
            guard let defaults else { throw KeyboardHandoffStoreError.unavailable }
            guard let current = mergedRecordUnlocked(now: now) else {
                throw KeyboardHandoffStoreError.noActiveRequest
            }
            guard current.requestID == requestID else {
                throw KeyboardHandoffStoreError.mismatchedRequest
            }
            guard current.phase == .recording else {
                throw KeyboardHandoffStoreError.invalidTransition
            }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let interim = InterimRecord(
                requestID: requestID,
                text: trimmed.isEmpty ? nil : trimmed,
                updatedAt: now
            )
            defaults.set(try JSONEncoder().encode(interim), forKey: Self.interimKey)
            if var status = readStatusUnlocked(), status.requestID == requestID {
                status.expiresAt = now.addingTimeInterval(Self.requestLifetime)
                status.updatedAt = now
                writeStatusRecordUnlocked(status)
            }
            defaults.synchronize()
            guard let updated = mergedRecordUnlocked(now: now) else {
                throw KeyboardHandoffStoreError.noActiveRequest
            }
            return updated
        }
    }

    // MARK: - Reading

    public func record(matching requestID: UUID, now: Date = Date()) -> KeyboardHandoffRecord? {
        lock.withLock {
            guard let record = mergedRecordUnlocked(now: now), record.requestID == requestID else {
                return nil
            }
            return record
        }
    }

    public func activeRecord(now: Date = Date()) -> KeyboardHandoffRecord? {
        lock.withLock {
            mergedRecordUnlocked(now: now)
        }
    }

    /// Returns and then promptly removes only the matching, unexpired result.
    public func consumeResult(
        requestID: UUID,
        documentIdentifier: UUID? = nil,
        now: Date = Date()
    ) -> String? {
        lock.withLock {
            guard let record = mergedRecordUnlocked(now: now),
                  record.requestID == requestID,
                  record.phase == .completed,
                  record.targetDocumentIdentifier == nil
                    || record.targetDocumentIdentifier == documentIdentifier,
                  let transcript = record.transcript,
                  !transcript.isEmpty else {
                return nil
            }
            removeAllUnlocked()
            return transcript
        }
    }

    /// Removes only the caller's request, so an old process cannot clear a
    /// newer request after suspension.
    public func clear(requestID: UUID) {
        lock.withLock {
            guard readIntentUnlocked()?.requestID == requestID else { return }
            removeAllUnlocked()
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

// MARK: - Writes

extension KeyboardHandoffStore {
    /// Records an extension intent in the extension-owned command channel.
    /// Commands only escalate (`finish` → `cancel`); a stale lower command can
    /// never replace a newer one, and terminal app phases refuse commands.
    func issueCommand(
        _ command: Command,
        requestID: UUID,
        allowedFrom: Set<KeyboardHandoffRecord.Phase>,
        now: Date
    ) throws -> KeyboardHandoffRecord {
        try lock.withLock {
            guard let defaults else { throw KeyboardHandoffStoreError.unavailable }
            guard var intent = readIntentUnlocked() else {
                throw KeyboardHandoffStoreError.noActiveRequest
            }
            guard intent.requestID == requestID else {
                throw KeyboardHandoffStoreError.mismatchedRequest
            }
            guard let current = mergedRecordUnlocked(now: now),
                  allowedFrom.contains(current.phase) else {
                throw KeyboardHandoffStoreError.invalidTransition
            }
            // Monotonic command channel: cancel outranks finish outranks none.
            guard commandRank(command) > commandRank(intent.command) else {
                guard let record = mergedRecordUnlocked(now: now) else {
                    throw KeyboardHandoffStoreError.noActiveRequest
                }
                return record
            }
            intent.command = command
            intent.commandSequence += 1
            intent.commandIssuedAt = now
            intent.expiresAt = now.addingTimeInterval(Self.transcriptionLifetime)
            defaults.set(try JSONEncoder().encode(intent), forKey: Self.intentKey)
            defaults.synchronize()
            guard let record = mergedRecordUnlocked(now: now) else {
                throw KeyboardHandoffStoreError.noActiveRequest
            }
            return record
        }
    }

    func commandRank(_ command: Command) -> Int {
        switch command {
        case .none: return 0
        case .finish: return 1
        case .cancel: return 2
        }
    }

    /// App-owned status write. Transitions validate against the merged view
    /// (so a pending extension cancel blocks app transitions) and are
    /// monotonic: a terminal phase is absorbing.
    func writeStatus(
        requestID: UUID,
        allowedFrom: Set<KeyboardHandoffRecord.Phase>,
        phase: KeyboardHandoffRecord.Phase,
        transcript: String? = nil,
        failureCode: KeyboardHandoffRecord.FailureCode? = nil,
        now: Date,
        lifetime: TimeInterval
    ) throws -> KeyboardHandoffRecord {
        try lock.withLock {
            guard let defaults else { throw KeyboardHandoffStoreError.unavailable }
            guard let current = mergedRecordUnlocked(now: now) else {
                throw KeyboardHandoffStoreError.noActiveRequest
            }
            guard current.requestID == requestID else {
                throw KeyboardHandoffStoreError.mismatchedRequest
            }
            guard allowedFrom.contains(current.phase) else {
                throw KeyboardHandoffStoreError.invalidTransition
            }
            let status = StatusRecord(
                requestID: requestID,
                phase: phase,
                updatedAt: now,
                expiresAt: now.addingTimeInterval(lifetime),
                transcript: transcript,
                failureCode: failureCode
            )
            writeStatusRecordUnlocked(status)
            if !phaseKeepsInterim(phase) {
                defaults.removeObject(forKey: Self.interimKey)
            }
            defaults.synchronize()
            guard let record = mergedRecordUnlocked(now: now) else {
                throw KeyboardHandoffStoreError.noActiveRequest
            }
            return record
        }
    }

    func phaseKeepsInterim(_ phase: KeyboardHandoffRecord.Phase) -> Bool {
        phase == .recording || phase == .finishRequested || phase == .transcribing
    }

    func writeStatusRecordUnlocked(_ status: StatusRecord) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        defaults?.set(data, forKey: Self.statusKey)
    }

    func removeAllUnlocked() {
        defaults?.removeObject(forKey: Self.intentKey)
        defaults?.removeObject(forKey: Self.statusKey)
        defaults?.removeObject(forKey: Self.interimKey)
        defaults?.removeObject(forKey: Self.legacyRecordKey)
        defaults?.synchronize()
    }
}
