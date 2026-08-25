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
