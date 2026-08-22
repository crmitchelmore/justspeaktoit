import Foundation

// MARK: - Stored layouts

extension KeyboardHandoffStore {
    enum Command: String, Codable {
        case none
        case finish
        case cancel
    }

    struct IntentRecord: Codable {
        var schemaVersion: Int = 1
        let requestID: UUID
        let createdAt: Date
        var expiresAt: Date
        let targetDocumentIdentifier: UUID?
        let profile: KeyboardDictationProfileOption?
        var command: Command = .none
        var commandSequence: Int = 0
        var commandIssuedAt: Date?
    }

    struct StatusRecord: Codable {
        var schemaVersion: Int = 1
        let requestID: UUID
        var phase: KeyboardHandoffRecord.Phase
        var updatedAt: Date
        var expiresAt: Date
        var transcript: String?
        var failureCode: KeyboardHandoffRecord.FailureCode?
    }

    struct InterimRecord: Codable {
        let requestID: UUID
        let text: String?
        let updatedAt: Date
    }
}

// MARK: - Merged view

extension KeyboardHandoffStore {
    func readIntentUnlocked() -> IntentRecord? {
        guard let data = defaults?.data(forKey: Self.intentKey),
              let intent = try? JSONDecoder().decode(IntentRecord.self, from: data),
              intent.schemaVersion == 1 else {
            return nil
        }
        return intent
    }

    func readStatusUnlocked() -> StatusRecord? {
        guard let data = defaults?.data(forKey: Self.statusKey),
              let status = try? JSONDecoder().decode(StatusRecord.self, from: data),
              status.schemaVersion == 1 else {
            return nil
        }
        return status
    }

    func readInterimUnlocked() -> InterimRecord? {
        guard let data = defaults?.data(forKey: Self.interimKey),
              let interim = try? JSONDecoder().decode(InterimRecord.self, from: data) else {
            return nil
        }
        return interim
    }

    /// Builds the effective record from the single-writer keys. Expiry is
    /// derived here and never written back, so reads cannot race writers.
    func mergedRecordUnlocked(now: Date) -> KeyboardHandoffRecord? {
        guard let intent = readIntentUnlocked() else { return nil }
        let status: StatusRecord? = {
            guard let status = readStatusUnlocked(), status.requestID == intent.requestID else {
                return nil
            }
            return status
        }()

        var phase: KeyboardHandoffRecord.Phase = status?.phase ?? .requested
        // Extension commands modulate non-terminal app phases; a cancel always
        // wins over anything the app might still write.
        let terminal: Set<KeyboardHandoffRecord.Phase> = [.completed, .cancelled, .failed]
        if !terminal.contains(phase) {
            switch intent.command {
            case .cancel:
                phase = .cancelled
            case .finish:
                if phase == .recording { phase = .finishRequested }
            case .none:
                break
            }
        }

        let expiresAt = max(status?.expiresAt ?? .distantPast, intent.expiresAt)
        let updatedAt = max(status?.updatedAt ?? intent.createdAt, intent.commandIssuedAt ?? .distantPast)

        if expiresAt <= now {
            // Expired terminal records simply disappear; anything else is
            // reported as timed out — derived, not written, so this
            // normalisation cannot race a writer in either process.
            if terminal.contains(phase) { return nil }
            return timedOutRecord(of: intent, storedExpiry: expiresAt, now: now)
        }

        let interim: String? = {
            guard phaseKeepsInterim(phase),
                  let record = readInterimUnlocked(),
                  record.requestID == intent.requestID else {
                return nil
            }
            return record.text
        }()

        return KeyboardHandoffRecord(
            requestID: intent.requestID,
            createdAt: intent.createdAt,
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            phase: phase,
            targetDocumentIdentifier: intent.targetDocumentIdentifier,
            profile: intent.profile,
            interimTranscript: interim,
            transcript: phase == .completed ? status?.transcript : nil,
            failureCode: phase == .failed ? (status?.failureCode ?? .unknown) : nil
        )
    }
    /// The timed-out view of a non-terminal request keeps a fixed expiry
    /// anchored to the stored one (`storedExpiry + resultLifetime`), so
    /// repeated reads cannot extend it; past that point the record is gone.
    func timedOutRecord(of intent: IntentRecord, storedExpiry: Date, now: Date) -> KeyboardHandoffRecord? {
        let timedOutExpiresAt = storedExpiry.addingTimeInterval(Self.resultLifetime)
        guard timedOutExpiresAt > now else { return nil }
        return timedOutView(of: intent, timedOutAt: storedExpiry, expiresAt: timedOutExpiresAt)
    }

    func timedOutView(of intent: IntentRecord, timedOutAt: Date, expiresAt: Date) -> KeyboardHandoffRecord {
        KeyboardHandoffRecord(
            requestID: intent.requestID,
            createdAt: intent.createdAt,
            updatedAt: timedOutAt,
            expiresAt: expiresAt,
            phase: .failed,
            targetDocumentIdentifier: intent.targetDocumentIdentifier,
            profile: intent.profile,
            failureCode: .timedOut
        )
    }

}
