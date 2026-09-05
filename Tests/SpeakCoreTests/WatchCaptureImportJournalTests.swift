import XCTest

@testable import SpeakCore

/// Durable Watch-import journalling (issue #674): jobs are parked
/// idempotently, survive relaunch, retry with bounded attempts, purge under
/// retention, and acknowledgements persist until the transport confirms
/// delivery.
final class WatchCaptureImportJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private func makeJournal() -> WatchCaptureImportJournal {
        WatchCaptureImportJournal(directoryURL: directory)
    }

    func testParkJob_isIdempotentPerCaptureAndSurvivesRelaunch() {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 12)
        // Re-delivery of the same capture must not duplicate the job.
        journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 12)
        XCTAssertEqual(journal.pendingJobs().count, 1)

        // A process death is survived: a fresh journal instance re-reads the
        // same pending job from disk.
        let relaunched = makeJournal()
        XCTAssertEqual(relaunched.pendingJobs().map(\.captureID), [captureID])
    }

    func testAttemptFailures_areBoundedAndPurgedWithTerminalOutcome() {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 5)

        for attempt in 1...WatchCaptureImportJournal.defaultMaximumAttempts {
            XCTAssertEqual(
                journal.isRetryable(captureID: captureID),
                attempt <= WatchCaptureImportJournal.defaultMaximumAttempts,
                "attempt \(attempt)"
            )
            journal.recordAttemptFailure(captureID: captureID, message: "network down")
        }
        XCTAssertFalse(journal.isRetryable(captureID: captureID))

        let purged = journal.purgeExpired()
        XCTAssertEqual(purged.map(\.captureID), [captureID])
        XCTAssertEqual(purged.first?.lastErrorMessage, "network down")
        XCTAssertTrue(journal.pendingJobs().isEmpty)
    }

    func testRetention_purgesJobsOlderThanTheWindowEvenWithAttemptsLeft() {
        let journal = makeJournal()
        let stale = UUID()
        let fresh = UUID()
        journal.parkJobReportingDurability(
            captureID: stale,
            fileExtension: "m4a",
            createdAt: Date().addingTimeInterval(-15 * 24 * 60 * 60),
            duration: 5,
            now: Date().addingTimeInterval(-15 * 24 * 60 * 60)
        )
        journal.parkJob(captureID: fresh, fileExtension: "m4a", createdAt: Date(), duration: 5)

        let purged = journal.purgeExpired()
        XCTAssertEqual(purged.map(\.captureID), [stale])
        XCTAssertEqual(journal.pendingJobs().map(\.captureID), [fresh])
    }

    func testCompleteJob_removesOnlyThatCapture() {
        let journal = makeJournal()
        let first = UUID()
        let second = UUID()
        journal.parkJob(captureID: first, fileExtension: "m4a", createdAt: Date(), duration: 1)
        journal.parkJob(captureID: second, fileExtension: "m4a", createdAt: Date(), duration: 1)

        journal.completeJob(captureID: first)
        XCTAssertEqual(journal.pendingJobs().map(\.captureID), [second])

        // Completion is idempotent, and a completed capture re-parked later
        // (a true re-delivery after completion) journals cleanly again.
        journal.completeJob(captureID: first)
        journal.parkJob(captureID: first, fileExtension: "m4a", createdAt: Date(), duration: 1)
        XCTAssertEqual(journal.pendingJobs().count, 2)
    }

    func testAcks_persistUntilDeliveryConfirmedAndSurviveRelaunch() {
        let journal = makeJournal()
        let captureID = UUID()
        journal.recordPendingAck(WatchCaptureAckRecord(captureID: captureID, outcome: .transcribed))

        // Failed transport delivery keeps the record for the next replay…
        XCTAssertEqual(makeJournal().pendingAcks().map(\.captureID), [captureID])

        // …a newer outcome replaces rather than duplicates…
        journal.recordPendingAck(WatchCaptureAckRecord(
            captureID: captureID,
            outcome: .failed,
            message: "gone"
        ))
        XCTAssertEqual(journal.pendingAcks().count, 1)
        XCTAssertEqual(journal.pendingAcks().first?.outcome, .failed)

        // …and confirmation clears it durably.
        journal.confirmAckDelivered(captureID: captureID)
        XCTAssertTrue(journal.pendingAcks().isEmpty)
        XCTAssertTrue(makeJournal().pendingAcks().isEmpty)
    }

    func testParkWriteFailure_reportsFailureAndCanRetryAfterStorageRecovers() throws {
        let journal = makeJournal()
        let captureID = UUID()
        try withBlockedJournal {
            XCTAssertFalse(journal.parkJobReportingDurability(
                captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 5
            ))
            XCTAssertTrue(journal.pendingJobs().isEmpty)
        }
        XCTAssertTrue(journal.parkJobReportingDurability(
            captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 5
        ))
        XCTAssertEqual(makeJournal().pendingJobs().map(\.captureID), [captureID])
    }

    func testCompleteWithAcknowledgement_persistsBothChangesTogether() {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 5)

        XCTAssertTrue(journal.completeJobReportingDurability(
            captureID: captureID,
            acknowledgement: WatchCaptureAckRecord(captureID: captureID, outcome: .transcribed)
        ))

        let relaunched = makeJournal()
        XCTAssertTrue(relaunched.pendingJobs().isEmpty)
        XCTAssertEqual(relaunched.pendingAcks().map(\.captureID), [captureID])
        XCTAssertEqual(relaunched.pendingAcks().first?.outcome, .transcribed)
    }

    func testCompletionWriteFailure_keepsJobAndDoesNotExposeUncommittedAck() throws {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 5)
        let acknowledgement = WatchCaptureAckRecord(captureID: captureID, outcome: .transcribed)

        try withBlockedJournal {
            XCTAssertFalse(journal.completeJobReportingDurability(
                captureID: captureID, acknowledgement: acknowledgement
            ))
            XCTAssertEqual(journal.pendingJobs().map(\.captureID), [captureID])
            XCTAssertTrue(journal.pendingAcks().isEmpty)
        }
        XCTAssertEqual(makeJournal().pendingJobs().map(\.captureID), [captureID])
        XCTAssertTrue(journal.completeJobReportingDurability(
            captureID: captureID, acknowledgement: acknowledgement
        ))
        XCTAssertEqual(makeJournal().pendingAcks().map(\.captureID), [captureID])
    }

    func testPurge_persistsFailureAckBeforeReleasingExpiredJob() {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJobReportingDurability(
            captureID: captureID, fileExtension: "m4a",
            createdAt: Date().addingTimeInterval(-15 * 24 * 60 * 60), duration: 5,
            now: Date().addingTimeInterval(-15 * 24 * 60 * 60)
        )
        journal.recordAttemptFailure(captureID: captureID, message: "network unavailable")

        XCTAssertEqual(journal.purgeExpired().map(\.captureID), [captureID])
        let relaunched = makeJournal()
        XCTAssertTrue(relaunched.pendingJobs().isEmpty)
        XCTAssertEqual(relaunched.pendingAcks().first?.outcome, .failed)
        XCTAssertEqual(relaunched.pendingAcks().first?.message, "network unavailable")
    }

    func testPurgeWriteFailure_returnsNoAudioToDeleteAndKeepsJobRetryable() throws {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJobReportingDurability(
            captureID: captureID, fileExtension: "m4a",
            createdAt: Date().addingTimeInterval(-15 * 24 * 60 * 60), duration: 5,
            now: Date().addingTimeInterval(-15 * 24 * 60 * 60)
        )

        try withBlockedJournal {
            XCTAssertTrue(journal.purgeExpired().isEmpty)
            XCTAssertEqual(journal.pendingJobs().map(\.captureID), [captureID])
            XCTAssertTrue(journal.pendingAcks().isEmpty)
        }
        XCTAssertEqual(makeJournal().pendingJobs().map(\.captureID), [captureID])
        XCTAssertEqual(journal.purgeExpired().map(\.captureID), [captureID])
    }

    func testAckConfirmationWriteFailure_keepsAckAvailableForReplay() throws {
        let journal = makeJournal()
        let captureID = UUID()
        journal.recordPendingAck(WatchCaptureAckRecord(captureID: captureID, outcome: .transcribed))

        try withBlockedJournal {
            journal.confirmAckDelivered(captureID: captureID)
            XCTAssertEqual(journal.pendingAcks().map(\.captureID), [captureID])
        }
        XCTAssertEqual(makeJournal().pendingAcks().map(\.captureID), [captureID])
        journal.confirmAckDelivered(captureID: captureID)
        XCTAssertTrue(makeJournal().pendingAcks().isEmpty)
    }

    /// Replace the parent directory with a regular file, preserving the last
    /// durable snapshot. This forces ENOTDIR even when tests run as root.
    private func withBlockedJournal(_ body: () throws -> Void) throws {
        let backup = directory.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.moveItem(at: backup, to: directory)
        }
        try Data("blocked".utf8).write(to: directory)
        try body()
    }

    func testRedeliveryAfterConfirmedAckAndRelaunch_replaysReceiptWithoutRetranscription() {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 5)
        XCTAssertTrue(journal.completeJobReportingDurability(
            captureID: captureID,
            acknowledgement: WatchCaptureAckRecord(captureID: captureID, outcome: .transcribed)
        ))
        journal.confirmAckDelivered(captureID: captureID)

        // Transport delivered the ack, but the watch may have died before its
        // handler persisted it. Its next activation resends the retained audio.
        let relaunched = makeJournal()
        XCTAssertTrue(relaunched.pendingAcks().isEmpty)
        XCTAssertEqual(relaunched.completedAcknowledgement(captureID: captureID)?.outcome, .transcribed)
        XCTAssertTrue(relaunched.parkJobReportingDurability(
            captureID: captureID, fileExtension: "m4a", createdAt: Date(), duration: 5
        ))
        XCTAssertTrue(relaunched.pendingJobs().isEmpty)
        XCTAssertEqual(makeJournal().pendingAcks().map(\.captureID), [captureID])
    }

    func testExpiredSuccessReceipt_allowsBoundedRetentionAndReimport() {
        let journal = makeJournal()
        let captureID = UUID()
        XCTAssertTrue(journal.completeJobReportingDurability(
            captureID: captureID,
            acknowledgement: WatchCaptureAckRecord(
                captureID: captureID, outcome: .transcribed,
                recordedAt: Date().addingTimeInterval(-15 * 24 * 60 * 60)
            )
        ))
        journal.confirmAckDelivered(captureID: captureID)
        XCTAssertNil(makeJournal().completedAcknowledgement(captureID: captureID))
        // Real retransfers retain the original capture date. Retention must
        // start at this phone arrival, or recovery purges it before import.
        let originalDate = Date().addingTimeInterval(-15 * 24 * 60 * 60)
        journal.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: originalDate, duration: 5)
        let relaunched = makeJournal()
        XCTAssertTrue(relaunched.purgeExpired().isEmpty)
        XCTAssertEqual(relaunched.pendingJobs().map(\.captureID), [captureID])
        XCTAssertTrue(relaunched.pendingAcks().isEmpty)
    }

    func testLegacyJournalWithoutReceipts_retainsPendingJobsOnUpgrade() throws {
        let captureID = UUID()
        let legacyJSON = """
        {"jobs":[{"captureID":"\(captureID.uuidString)","fileExtension":"m4a",
        "createdAt":"2026-08-06T12:00:00Z","duration":5,"attempts":0,
        "updatedAt":"2026-08-06T12:00:00Z"}],"pendingAcks":[]}
        """
        try Data(legacyJSON.utf8).write(to: directory.appendingPathComponent("import-journal.json"))
        let journal = makeJournal()
        XCTAssertEqual(journal.pendingJobs().map(\.captureID), [captureID])
        XCTAssertNil(journal.pendingJobs().first?.parkedAt)
        XCTAssertEqual(journal.purgeExpired(now: .distantFuture).map(\.captureID), [captureID])
    }

    func testAckRecord_bridgesToTheWireAck() {
        let captureID = UUID()
        let record = WatchCaptureAckRecord(captureID: captureID, outcome: .failed, message: "why")
        XCTAssertEqual(record.ack, WatchCaptureAck(id: captureID, outcome: .failed, message: "why"))
    }
}
