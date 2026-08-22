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
        journal.parkJob(
            captureID: stale,
            fileExtension: "m4a",
            createdAt: Date().addingTimeInterval(-15 * 24 * 60 * 60),
            duration: 5
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

    func testAckRecord_bridgesToTheWireAck() {
        let captureID = UUID()
        let record = WatchCaptureAckRecord(captureID: captureID, outcome: .failed, message: "why")
        XCTAssertEqual(record.ack, WatchCaptureAck(id: captureID, outcome: .failed, message: "why"))
    }
}
