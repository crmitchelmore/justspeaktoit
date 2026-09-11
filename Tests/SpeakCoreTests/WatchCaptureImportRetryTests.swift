import XCTest
@testable import SpeakCore

// MARK: - Transient retry eligibility

final class WatchCaptureImportRetryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("watch-retry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeJournal() -> WatchCaptureImportJournal {
        WatchCaptureImportJournal(directoryURL: directory)
    }

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

    func testTransientFailures_persistBoundedBackoffWithoutSpendingAttemptsOrRefreshingRetention() throws {
        let captureID = UUID()
        let origin = Date(timeIntervalSince1970: 1_789_000_000)
        var now = origin
        let journal = makeJournal()
        journal.parkJobReportingDurability(
            captureID: captureID, fileExtension: "m4a", createdAt: origin, duration: 5, now: origin
        )
        for expectedDelay in [30.0, 60, 120, 240, 480, 900, 900] {
            XCTAssertTrue(journal.recordTransientFailure(captureID: captureID, message: "offline", now: now))
            let relaunched = makeJournal()
            let job = try XCTUnwrap(relaunched.pendingJobs().first)
            XCTAssertEqual(job.attempts, 0)
            XCTAssertEqual(job.retryDelay, expectedDelay)
            XCTAssertEqual(job.parkedAt, origin)
            XCTAssertEqual(job.lastErrorMessage, "offline")
            let deadline = try XCTUnwrap(job.nextRetryAt)
            XCTAssertFalse(relaunched.isRetryable(captureID: captureID, now: deadline.addingTimeInterval(-1)))
            XCTAssertTrue(relaunched.isRetryable(captureID: captureID, now: deadline))
            relaunched.parkJob(captureID: captureID, fileExtension: "m4a", createdAt: now, duration: 5)
            XCTAssertEqual(relaunched.pendingJobs().first, job)
            XCTAssertTrue(relaunched.purgeExpired(now: deadline).isEmpty)
            XCTAssertTrue(relaunched.pendingAcks().isEmpty)
            now = deadline
        }
        XCTAssertEqual(journal.purgeExpired(now: origin.addingTimeInterval(15 * 24 * 60 * 60))
            .map(\.captureID), [captureID])
        XCTAssertEqual(makeJournal().pendingAcks().first?.outcome, .failed)
    }

    func testTransientFailureWriteFailure_preservesDurableJobAndRecovery() throws {
        let journal = makeJournal()
        let captureID = UUID()
        journal.parkJobReportingDurability(
            captureID: captureID, fileExtension: "m4a", createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            duration: 5, now: Date(timeIntervalSince1970: 1_789_000_000)
        )
        let before = journal.pendingJobs()
        try withBlockedJournal {
            XCTAssertFalse(journal.recordTransientFailure(captureID: captureID, message: "offline"))
            XCTAssertEqual(journal.pendingJobs(), before)
            XCTAssertTrue(journal.pendingAcks().isEmpty)
        }
        XCTAssertEqual(makeJournal().pendingJobs(), before)
        XCTAssertTrue(journal.recordTransientFailure(captureID: captureID, message: "offline"))
        XCTAssertNotNil(makeJournal().pendingJobs().first?.nextRetryAt)
    }
}
