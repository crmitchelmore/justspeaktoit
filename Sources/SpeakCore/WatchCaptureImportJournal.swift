import Foundation

/// Durable record of one delivered-but-not-yet-imported Watch capture
/// (issue #674). The job is parked the moment the audio file is, so a
/// suspended or killed import is rediscovered on the next activation or
/// foreground entry instead of stranding the audio (and the Watch at
/// "Delivered") forever.
public struct WatchCaptureImportJob: Codable, Equatable, Sendable {
    public let captureID: UUID
    public let fileExtension: String
    public let createdAt: Date
    public let duration: TimeInterval
    public var attempts: Int
    public var lastErrorMessage: String?
    public var updatedAt: Date
    /// First arrival on this phone, distinct from recording time. Optional
    /// so legacy journals decode using the original capture-time retention.
    let parkedAt: Date?

    public init(
        captureID: UUID,
        fileExtension: String,
        createdAt: Date,
        duration: TimeInterval,
        attempts: Int = 0,
        lastErrorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.captureID = captureID
        self.fileExtension = fileExtension
        self.createdAt = createdAt
        self.duration = duration
        self.attempts = attempts
        self.lastErrorMessage = lastErrorMessage
        self.updatedAt = updatedAt
        self.parkedAt = updatedAt
    }
}

/// An acknowledgement owed to the Watch, retained until its delivery is
/// confirmed so a failed `transferUserInfo` cannot leave the Watch at
/// "Delivered" while the phone already holds the history entry (issue #674).
public struct WatchCaptureAckRecord: Codable, Equatable, Sendable {
    public let captureID: UUID
    public let outcome: WatchCaptureAck.Outcome
    public let message: String?
    public let recordedAt: Date

    public init(
        captureID: UUID,
        outcome: WatchCaptureAck.Outcome,
        message: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.captureID = captureID
        self.outcome = outcome
        self.message = message
        self.recordedAt = recordedAt
    }

    public var ack: WatchCaptureAck {
        WatchCaptureAck(id: captureID, outcome: outcome, message: message)
    }
}

/// File-backed journal for Watch capture imports and their acknowledgements
/// (issue #674).
///
/// One JSON document beside the parked audio holds every pending import job
/// and undelivered acknowledgement. All operations are idempotent by capture
/// UUID: re-delivery of a capture, a crashed import retried after relaunch,
/// or a replayed acknowledgement does not duplicate pending records.
/// Retention is bounded: jobs that exhausted their attempts or outlived the
/// retention window are purged (with their audio) rather than
/// accumulating as unrecoverable failures.
public final class WatchCaptureImportJournal: @unchecked Sendable {
    /// One import may run at a time; retries use bounded attempts.
    public static let defaultMaximumAttempts = 5
    /// Failed captures are kept for a fortnight before being reclaimed.
    public static let defaultRetentionInterval: TimeInterval = 14 * 24 * 60 * 60

    private struct State: Codable {
        var jobs: [WatchCaptureImportJob] = []
        var pendingAcks: [WatchCaptureAckRecord] = []
        // Optional for backward-compatible decoding of journals before receipts.
        var completedAcks: [WatchCaptureAckRecord]?
    }

    private let lock = NSLock()
    private let journalURL: URL
    private var state: State

    /// - Parameter directoryURL: the parked-captures directory; the journal
    ///   document lives beside the audio it describes.
    public init(directoryURL: URL) {
        self.journalURL = directoryURL.appendingPathComponent(
            "import-journal.json",
            isDirectory: false
        )
        if let data = try? Data(contentsOf: journalURL),
           let decoded = try? JSONDecoder.watchJournal.decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = State()
        }
    }

    // MARK: - Jobs

    /// Parks an import job for a delivered capture. Idempotent: re-delivery
    /// of a capture already journalled leaves the existing record untouched.
    public func parkJob(
        captureID: UUID,
        fileExtension: String,
        createdAt: Date,
        duration: TimeInterval
    ) {
        parkJobReportingDurability(
            captureID: captureID,
            fileExtension: fileExtension,
            createdAt: createdAt,
            duration: duration
        )
    }

    /// Parks a job and reports whether its recovery record reached disk.
    @discardableResult
    public func parkJobReportingDurability(
        captureID: UUID,
        fileExtension: String,
        createdAt: Date,
        duration: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        withState { state in
            if let completed = Self.completedAcknowledgement(in: state, captureID: captureID) {
                state.pendingAcks.removeAll { $0.captureID == captureID }
                state.pendingAcks.append(completed)
                return
            }
            guard !state.jobs.contains(where: { $0.captureID == captureID }) else { return }
            // A redelivery is a new attempt after a prior terminal failure.
            state.pendingAcks.removeAll { $0.captureID == captureID }
            state.jobs.append(WatchCaptureImportJob(
                captureID: captureID,
                fileExtension: fileExtension,
                createdAt: createdAt,
                duration: duration,
                updatedAt: now
            ))
        }
    }

    /// Pending imports, oldest first.
    public func pendingJobs() -> [WatchCaptureImportJob] {
        lock.lock()
        defer { lock.unlock() }
        return state.jobs.sorted { $0.createdAt < $1.createdAt }
    }

    /// Records one failed import attempt and keeps the job retryable.
    public func recordAttemptFailure(captureID: UUID, message: String) {
        withState { state in
            guard let index = state.jobs.firstIndex(where: { $0.captureID == captureID }) else {
                return
            }
            state.jobs[index].attempts += 1
            state.jobs[index].lastErrorMessage = message
            state.jobs[index].updatedAt = Date()
        }
    }

    /// Whether the job may still be retried under the bounded attempt policy.
    public func isRetryable(
        captureID: UUID,
        maximumAttempts: Int = WatchCaptureImportJournal.defaultMaximumAttempts
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let job = state.jobs.first(where: { $0.captureID == captureID }) else { return false }
        return job.attempts < maximumAttempts
    }

    /// Removes a completed job. The acknowledgement lifecycle is separate.
    public func completeJob(captureID: UUID) {
        completeJobReportingDurability(captureID: captureID)
    }

    /// Removes a completed job and retains its terminal acknowledgement in
    /// the same atomic write. Callers may release audio only when this succeeds.
    @discardableResult
    public func completeJobReportingDurability(
        captureID: UUID,
        acknowledgement: WatchCaptureAckRecord? = nil
    ) -> Bool {
        withState { state in
            if let acknowledgement {
                state.pendingAcks.removeAll { $0.captureID == captureID }
                state.pendingAcks.append(acknowledgement)
                if acknowledgement.outcome == .transcribed {
                    var completed = state.completedAcks ?? []
                    completed.removeAll { $0.captureID == captureID }
                    completed.append(acknowledgement)
                    state.completedAcks = completed
                }
            }
            state.jobs.removeAll { $0.captureID == captureID }
        }
    }

    /// Purges jobs that exhausted their attempts or outlived retention.
    /// Atomically retains terminal failure acknowledgements before returning
    /// jobs whose audio may be deleted. A failed write leaves all jobs intact.
    public func purgeExpired(
        now: Date = Date(),
        retentionInterval: TimeInterval = WatchCaptureImportJournal.defaultRetentionInterval,
        maximumAttempts: Int = WatchCaptureImportJournal.defaultMaximumAttempts
    ) -> [WatchCaptureImportJob] {
        var purged: [WatchCaptureImportJob] = []
        let persisted = withState { state in
            let (expired, kept) = state.jobs.reduce(
                into: ([WatchCaptureImportJob](), [WatchCaptureImportJob]())
            ) { partition, job in
                let outOfAttempts = job.attempts >= maximumAttempts
                let outOfTime = now.timeIntervalSince(job.parkedAt ?? job.createdAt) > retentionInterval
                if outOfAttempts || outOfTime {
                    partition.0.append(job)
                } else {
                    partition.1.append(job)
                }
            }
            purged = expired
            state.jobs = kept
            for job in expired {
                state.pendingAcks.removeAll { $0.captureID == job.captureID }
                state.pendingAcks.append(WatchCaptureAckRecord(
                    captureID: job.captureID,
                    outcome: .failed,
                    message: job.lastErrorMessage
                        ?? "The capture could not be imported and was removed after retries."
                ))
            }
        }
        return persisted ? purged : []
    }

    // MARK: - Acknowledgements

    /// Retains an acknowledgement until delivery is confirmed. Idempotent by
    /// capture UUID; a newer outcome for the same capture replaces the old.
    public func recordPendingAck(_ record: WatchCaptureAckRecord) {
        recordPendingAckReportingDurability(record)
    }

    /// Retains an acknowledgement only if its recovery record reached disk.
    @discardableResult
    public func recordPendingAckReportingDurability(_ record: WatchCaptureAckRecord) -> Bool {
        withState { state in
            state.pendingAcks.removeAll { $0.captureID == record.captureID }
            state.pendingAcks.append(record)
        }
    }

    /// Success receipts survive transport confirmation, so a watch recovering
    /// a lost callback can request its acknowledgement without retranscription.
    /// Retained for the same fortnight as retryable imports; older redeliveries
    /// may be imported again under the existing stable history UUID.
    public func completedAcknowledgement(captureID: UUID) -> WatchCaptureAckRecord? {
        lock.lock()
        defer { lock.unlock() }
        return Self.completedAcknowledgement(in: state, captureID: captureID)
    }

    private static func completedAcknowledgement(in state: State, captureID: UUID) -> WatchCaptureAckRecord? {
        let cutoff = Date().addingTimeInterval(-defaultRetentionInterval)
        return state.pendingAcks.first { $0.captureID == captureID && $0.outcome == .transcribed }
            ?? state.completedAcks?.first { $0.captureID == captureID && $0.recordedAt >= cutoff }
    }

    /// Acknowledgements not yet confirmed delivered, oldest first.
    public func pendingAcks() -> [WatchCaptureAckRecord] {
        lock.lock()
        defer { lock.unlock() }
        return state.pendingAcks.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Clears an acknowledgement whose delivery the transport confirmed.
    public func confirmAckDelivered(captureID: UUID) {
        withState { state in
            state.pendingAcks.removeAll { $0.captureID == captureID }
        }
    }

    // MARK: - Persistence

    @discardableResult
    private func withState(_ mutate: (inout State) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var candidate = state
        let cutoff = Date().addingTimeInterval(-Self.defaultRetentionInterval)
        candidate.completedAcks?.removeAll { $0.recordedAt < cutoff }
        mutate(&candidate)
        do {
            let data = try JSONEncoder.watchJournal.encode(candidate)
            try data.write(to: journalURL, options: [.atomic])
            // Publish only durable state: failed writes must neither expose an
            // unsaved acknowledgement nor forget a job or an undelivered ack.
            state = candidate
            return true
        } catch {
            // The journal is the recovery record; a failed write must not
            // crash the import path, but it must be visible in diagnostics.
            SpeakLogger.logError(error, context: "WatchCaptureImportJournal.persist")
            return false
        }
    }
}

private extension JSONEncoder {
    static var watchJournal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var watchJournal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
