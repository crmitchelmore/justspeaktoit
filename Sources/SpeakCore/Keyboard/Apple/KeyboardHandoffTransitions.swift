import Foundation

// MARK: - App-side phase transitions

extension KeyboardHandoffStore {
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
        let record = try lock.withLock {
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
        announceIfContainingApp()
        return record
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
