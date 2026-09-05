#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class WatchCaptureImportPipelineTests: XCTestCase {
    func testArrivalsDuringImport_scheduleOneFiniteFollowupWithFreshCleanupAndAckReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-import-passes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = WatchCaptureImportPipeline(inboxDirectory: directory)
        defer { pipeline.importJobExecutor = nil }
        let first = UUID()
        let later = UUID()
        let expired = UUID()
        let acks = AckRecorder()
        var imported: [UUID] = []
        var scheduled: [@MainActor () async -> Void] = []
        pipeline.scheduleNextPass = { scheduled.append($0) }
        pipeline.sendAck = { acks.append($0) }
        pipeline.journal.parkJob(captureID: first, fileExtension: "m4a", createdAt: Date(), duration: 5)
        pipeline.importJobExecutor = { job in
            imported.append(job.captureID)
            if job.captureID == first {
                XCTAssertTrue(pipeline.journal.completeJobReportingDurability(
                    captureID: first,
                    acknowledgement: WatchCaptureAckRecord(captureID: first, outcome: .transcribed)
                ))
                pipeline.journal.parkJob(captureID: later, fileExtension: "m4a", createdAt: Date(), duration: 5)
                pipeline.journal.parkJobReportingDurability(
                    captureID: expired, fileExtension: "m4a", createdAt: Date(), duration: 5,
                    now: Date().addingTimeInterval(-15 * 24 * 60 * 60)
                )
                // Multiple arrival/foreground callbacks while this pass is
                // suspended must coalesce instead of extending its snapshot.
                await pipeline.processPendingImports()
                await pipeline.processPendingImports()
            } else {
                XCTAssertEqual(job.captureID, later)
                pipeline.journal.completeJob(captureID: later)
            }
        }

        await pipeline.processPendingImports()
        XCTAssertEqual(imported, [first])
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertTrue(acks.values.isEmpty)

        let followup = scheduled.removeFirst()
        await followup()
        XCTAssertEqual(imported, [first, later])
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(pipeline.journal.pendingJobs().isEmpty)
        XCTAssertEqual(Set(acks.values.map(\.id)), [first, expired])
        XCTAssertEqual(acks.values.first(where: { $0.id == expired })?.outcome, .failed)
    }
}

private final class AckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledgements: [WatchCaptureAck] = []

    func append(_ acknowledgement: WatchCaptureAck) {
        lock.lock()
        defer { lock.unlock() }
        acknowledgements.append(acknowledgement)
    }

    var values: [WatchCaptureAck] {
        lock.lock()
        defer { lock.unlock() }
        return acknowledgements
    }
}
#endif
