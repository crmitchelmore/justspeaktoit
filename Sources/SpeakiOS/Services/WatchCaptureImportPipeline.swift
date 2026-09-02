#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Durable, recoverable import pipeline for Apple Watch captures
/// (issue #674).
///
/// The WatchConnectivity receiver stays a thin shim: it parks the delivered
/// file (synchronously, before the system reclaims its inbox), forwards
/// acknowledgement transport, and triggers processing. Everything else —
/// journalled jobs, bounded retries with an expiration-safe background task,
/// history persistence that must succeed before anything is acknowledged or
/// deleted, terminal retention, and acknowledgement replay — lives here,
/// where it is compiled by CI and reachable from tests.
@MainActor
public final class WatchCaptureImportPipeline: ObservableObject {
    public static let shared = WatchCaptureImportPipeline()

    /// Directory where delivered captures are parked until their import has
    /// fully completed (history write durable, acknowledgement recorded).
    nonisolated public static var inboxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WatchCaptures", isDirectory: true)
    }

    /// Sends one acknowledgement to the Watch. Set by the receiver, which
    /// owns the WCSession; delivery confirmation comes back through
    /// `handleAckTransferFinished`.
    nonisolated(unsafe) public var sendAck: (@Sendable (WatchCaptureAck) -> Void)?

    private let journal: WatchCaptureImportJournal
    private let inboxDirectory: URL
    private var isProcessing = false
    private var activeImportTask: Task<Void, Error>?

    public convenience init() {
        self.init(inboxDirectory: Self.inboxDirectory)
    }

    /// Test seam: an isolated inbox directory.
    public init(inboxDirectory: URL) {
        self.inboxDirectory = inboxDirectory
        self.journal = WatchCaptureImportJournal(directoryURL: inboxDirectory)
    }

    // MARK: - Delivery

    /// Moves a delivered capture into the durable inbox and journals its
    /// import job. Must complete synchronously on the caller's thread — the
    /// system reclaims a WatchConnectivity inbox file when the delegate
    /// callback returns. Idempotent per capture id.
    ///
    /// - Returns: `false` when the file could not be parked (the delivery
    ///   should be treated as not received so the Watch retries).
    nonisolated public func parkDeliveredFile(
        at temporaryURL: URL,
        envelope: WatchCaptureEnvelope
    ) -> Bool {
        let destination = inboxDirectory
            .appendingPathComponent(envelope.id.uuidString)
            .appendingPathExtension(envelope.fileExtension)
        do {
            try FileManager.default.createDirectory(
                at: inboxDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            SpeakLogger.logError(error, context: "WatchCaptureImportPipeline.park")
            return false
        }
        // The job is parked the moment the audio is: a process death after
        // this point is recovered by the next reconcile pass.
        journal.parkJob(
            captureID: envelope.id,
            fileExtension: envelope.fileExtension,
            createdAt: envelope.createdAt,
            duration: envelope.duration
        )
        return true
    }

    // MARK: - Processing

    /// Reconciles the inbox: purges expired jobs (deleting their audio and
    /// sending terminal failure acknowledgements), replays undelivered
    /// acknowledgements, and runs every retryable pending import serially.
    /// Call on activation and on foreground entry; safe to call repeatedly.
    public func processPendingImports() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        purgeExpiredJobs()
        replayPendingAcks()

        for job in journal.pendingJobs() {
            guard journal.isRetryable(captureID: job.captureID) else { continue }
            await runImport(for: job)
        }
    }

    /// Runs one import under a background task whose expiration handler
    /// cancels the work cleanly, leaving the job journalled and retryable
    /// rather than assuming a network transcription fits the allowance.
    private func runImport(for job: WatchCaptureImportJob) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "WatchCaptureImport"
        ) { [weak self] in
            self?.activeImportTask?.cancel()
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        let importTask = Task { try await importOne(job) }
        activeImportTask = importTask
        defer { activeImportTask = nil }
        do {
            try await importTask.value
        } catch is CancellationError {
            journal.recordAttemptFailure(
                captureID: job.captureID,
                message: "Import interrupted by background expiration"
            )
        } catch {
            SpeakLogger.logError(error, context: "WatchCaptureImportPipeline.import")
            journal.recordAttemptFailure(
                captureID: job.captureID,
                message: error.localizedDescription
            )
        }
    }

    private func importOne(_ job: WatchCaptureImportJob) async throws {
        let audioURL = inboxDirectory
            .appendingPathComponent(job.captureID.uuidString)
            .appendingPathExtension(job.fileExtension)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completeUnrecoverable(job)
            return
        }

        let settings = AppSettings.shared
        // API keys load from the keychain asynchronously after init; a cold
        // background launch must wait for them before resolving the model.
        await settings.ensureKeysLoaded()
        try Task.checkCancellation()
        let model = settings.batchTranscriptionModel

        let result = try await IOSBatchTranscriber.transcribeFile(
            at: audioURL,
            model: model,
            apiKey: settings.batchAPIKey,
            language: settings.preferredModelLanguage,
            keywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords)
        )
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw IOSBatchTranscriptionError.emptyTranscript
        }

        // The history id is the capture id, so a re-delivered or re-imported
        // capture upserts the same row instead of duplicating it.
        let item = iOSHistoryItem(
            id: job.captureID,
            createdAt: job.createdAt,
            transcription: result.text,
            model: model,
            duration: result.duration > 0 ? result.duration : job.duration,
            wordCount: result.text.split(separator: " ").count,
            originPlatform: "watchos"
        )
        // Acknowledge and delete only after the history write is durable:
        // a full or unwritable store keeps the audio parked and the job
        // retryable instead of acknowledging data loss (issue #674).
        guard iOSHistoryManager.shared.upsertReportingDurability(item) else {
            journal.recordAttemptFailure(
                captureID: job.captureID,
                message: "History could not be written to disk."
            )
            return
        }
        SpeakLogger.logTranscription(
            event: "Watch capture transcribed",
            model: model,
            wordCount: item.wordCount
        )

        commitSuccessfulImport(of: job, audioURL: audioURL)

        if settings.autoPostProcess && settings.hasOpenRouterKey {
            await iOSHistoryManager.shared.reprocess(item)
        }
    }

    /// The audio is gone (e.g. reclaimed storage): the capture is
    /// unrecoverable, which is exactly what the Watch must learn.
    private func completeUnrecoverable(_ job: WatchCaptureImportJob) {
        journal.recordPendingAck(WatchCaptureAckRecord(
            captureID: job.captureID,
            outcome: .failed,
            message: "The capture's audio was no longer available on the phone."
        ))
        journal.completeJob(captureID: job.captureID)
        replayPendingAcks()
    }

    /// Records the durable success: acknowledgement retained until confirmed,
    /// job removed, parked audio released.
    private func commitSuccessfulImport(of job: WatchCaptureImportJob, audioURL: URL) {
        journal.recordPendingAck(WatchCaptureAckRecord(
            captureID: job.captureID,
            outcome: .transcribed
        ))
        journal.completeJob(captureID: job.captureID)
        try? FileManager.default.removeItem(at: audioURL)
        replayPendingAcks()
    }

    // MARK: - Acknowledgements

    /// Re-sends every acknowledgement whose delivery is unconfirmed.
    public func replayPendingAcks() {
        guard let sendAck else { return }
        for record in journal.pendingAcks() {
            sendAck(record.ack)
        }
    }

    /// Transport confirmation from the receiver's `didFinish` delegate: a
    /// confirmed delivery clears the retained acknowledgement; a failed one
    /// keeps it for the next replay, without retranscribing anything.
    nonisolated public func handleAckTransferFinished(captureID: UUID, delivered: Bool) {
        guard delivered else { return }
        journal.confirmAckDelivered(captureID: captureID)
    }

    // MARK: - Retention

    private func purgeExpiredJobs() {
        let purged = journal.purgeExpired()
        for job in purged {
            let audioURL = inboxDirectory
                .appendingPathComponent(job.captureID.uuidString)
                .appendingPathExtension(job.fileExtension)
            try? FileManager.default.removeItem(at: audioURL)
            journal.recordPendingAck(WatchCaptureAckRecord(
                captureID: job.captureID,
                outcome: .failed,
                message: job.lastErrorMessage
                    ?? "The capture could not be imported and was removed after retries."
            ))
        }
    }
}
#endif
