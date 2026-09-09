#if os(iOS)
import Foundation
import SpeakCore
import XCTest
import UIKit
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

@MainActor
extension WatchCaptureImportPipelineTests {
    func testTransientNetworkFailures_keepAudioAndBudgetThenRecoverOnceAfterRelaunch() async throws {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost, .timedOut] {
            let fixture = try RetryFixture()
            defer { fixture.cleanUp() }
            var pipeline = fixture.pipeline()
            var calls = 0
            for _ in 0..<6 {
                pipeline.transcribeAudio = { _ in calls += 1; throw URLError(code) }
                let before = calls
                await pipeline.processPendingImports()
                XCTAssertEqual(calls, before + 1)
                try fixture.assertRetained(pipeline)
                let deadline = try XCTUnwrap(pipeline.journal.pendingJobs().first?.nextRetryAt)
                for _ in 0..<3 {
                    XCTAssertTrue(pipeline.parkDeliveredFile(at: fixture.audioURL, envelope: fixture.envelope))
                    await pipeline.processPendingImports()
                }
                XCTAssertEqual(calls, before + 1)
                // A fresh pipeline reads eligibility from disk.
                pipeline = fixture.pipeline()
                pipeline.transcribeAudio = { _ in calls += 1; throw URLError(code) }
                fixture.now = deadline.addingTimeInterval(-1)
                await pipeline.processPendingImports()
                XCTAssertEqual(calls, before + 1)
                fixture.now = deadline
            }
            var history: [iOSHistoryItem] = []
            pipeline.persistHistory = { history.append($0); return true }
            pipeline.transcribeAudio = { _ in calls += 1; return RetryFixture.result }
            await pipeline.processPendingImports()
            XCTAssertEqual(calls, 7)
            XCTAssertEqual(history.map(\.id), [fixture.envelope.id])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
            let journal = WatchCaptureImportJournal(directoryURL: fixture.directory)
            XCTAssertTrue(journal.pendingJobs().isEmpty)
            XCTAssertEqual(journal.completedAcknowledgement(captureID: fixture.envelope.id)?.outcome, .transcribed)
            XCTAssertTrue(pipeline.parkDeliveredFile(at: fixture.audioURL, envelope: fixture.envelope))
            await pipeline.processPendingImports()
            XCTAssertEqual(calls, 7)
            XCTAssertEqual(history.count, 1)
        }
    }

    func testOwnedExpirations_bothCancellationFormsKeepAudioAndBudget() async throws {
        for urlCancellation in [false, true] {
            let fixture = try RetryFixture()
            defer { fixture.cleanUp() }
            let pipeline = fixture.pipeline()
            var expiration: (@MainActor @Sendable () -> Void)?
            pipeline.beginBackgroundTask = { expiration = $0; return UIBackgroundTaskIdentifier(rawValue: 42) }
            var ended = 0
            pipeline.endBackgroundTask = { _ in ended += 1 }
            pipeline.transcribeAudio = { _ in
                expiration?()
                if urlCancellation { throw URLError(.cancelled) }
                try Task.checkCancellation()
                return RetryFixture.result
            }
            for _ in 0..<6 {
                await pipeline.processPendingImports()
                try fixture.assertRetained(pipeline)
                XCTAssertEqual(pipeline.journal.pendingJobs().first?.lastErrorMessage,
                               "Import interrupted by background expiration")
                fixture.now = try XCTUnwrap(pipeline.journal.pendingJobs().first?.nextRetryAt)
            }
            XCTAssertEqual(ended, 6)
            // A callback retained from an ended allowance must not cancel its successor.
            let oldExpiration = expiration
            pipeline.transcribeAudio = { _ in
                oldExpiration?()
                try Task.checkCancellation()
                return RetryFixture.result
            }
            await pipeline.processPendingImports()
            XCTAssertTrue(pipeline.journal.pendingJobs().isEmpty)
            XCTAssertEqual(pipeline.journal.pendingAcks().first?.outcome, .transcribed)
        }
    }

    func testUnownedCancellationAndPermanentFailures_keepExistingAttemptLimit() async throws {
        let errors: [Error] = [CancellationError(), URLError(.cancelled), URLError(.userAuthenticationRequired),
                               IOSBatchTranscriptionError.httpError("OpenAI", 401, "invalid key"),
                               IOSBatchTranscriptionError.emptyTranscript]
        for error in errors {
            let fixture = try RetryFixture()
            defer { fixture.cleanUp() }
            let pipeline = fixture.pipeline()
            pipeline.transcribeAudio = { _ in throw error }
            for attempt in 1...5 {
                await pipeline.processPendingImports()
                XCTAssertEqual(pipeline.journal.pendingJobs().first?.attempts, attempt)
                XCTAssertNil(pipeline.journal.pendingJobs().first?.nextRetryAt)
            }
            await pipeline.processPendingImports()
            XCTAssertTrue(pipeline.journal.pendingJobs().isEmpty)
            XCTAssertEqual(pipeline.journal.pendingAcks().first?.outcome, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        }
    }

    func testDeferredJob_doesNotBlockOtherImportsAckReplayOrCleanup() async throws {
        let fixture = try RetryFixture()
        defer { fixture.cleanUp() }
        let pipeline = fixture.pipeline()
        pipeline.journal.recordTransientFailure(captureID: fixture.envelope.id, message: "offline", now: fixture.now)
        let expired = UUID()
        pipeline.journal.parkJobReportingDurability(
            captureID: expired, fileExtension: "m4a", createdAt: fixture.now, duration: 1,
            now: fixture.now.addingTimeInterval(-15 * 24 * 60 * 60)
        )
        let ready = UUID()
        let acknowledged = UUID()
        pipeline.journal.parkJob(captureID: ready, fileExtension: "m4a", createdAt: fixture.now, duration: 1)
        pipeline.journal.recordPendingAck(.init(captureID: acknowledged, outcome: .transcribed))
        var imports: [UUID] = []
        pipeline.importJobExecutor = { imports.append($0.captureID) }
        let acks = AckRecorder()
        pipeline.sendAck = { acks.append($0) }
        await pipeline.processPendingImports()
        XCTAssertEqual(imports, [ready])
        XCTAssertEqual(Set(acks.values.map(\.id)), [expired, acknowledged])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    func testSuccessJournalWriteFailure_keepsAudioAndDurableJobWithoutAcknowledgement() async throws {
        let fixture = try RetryFixture()
        defer { fixture.cleanUp() }
        let pipeline = fixture.pipeline()
        pipeline.transcribeAudio = { _ in RetryFixture.result }
        let journalURL = fixture.directory.appendingPathComponent("import-journal.json")
        let backupURL = fixture.directory.appendingPathComponent("journal-backup.json")
        pipeline.persistHistory = { _ in
            do {
                try FileManager.default.moveItem(at: journalURL, to: backupURL)
                try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
            } catch { XCTFail("Could not block journal: \(error)") }
            return true
        }
        await pipeline.processPendingImports()
        try fixture.assertRetained(pipeline)
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.moveItem(at: backupURL, to: journalURL)
        let relaunched = WatchCaptureImportJournal(directoryURL: fixture.directory)
        XCTAssertEqual(relaunched.pendingJobs().map(\.captureID), [fixture.envelope.id])
        XCTAssertTrue(relaunched.pendingAcks().isEmpty)
    }

    func testRecoveryHistoryWriteFailure_keepsAudioAndDoesNotAcknowledge() async throws {
        let fixture = try RetryFixture()
        defer { fixture.cleanUp() }
        let pipeline = fixture.pipeline()
        pipeline.transcribeAudio = { _ in throw URLError(.timedOut) }
        await pipeline.processPendingImports()
        fixture.now = try XCTUnwrap(pipeline.journal.pendingJobs().first?.nextRetryAt)
        pipeline.transcribeAudio = { _ in RetryFixture.result }
        pipeline.persistHistory = { _ in false }
        await pipeline.processPendingImports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertEqual(pipeline.journal.pendingJobs().first?.attempts, 1)
        XCTAssertTrue(pipeline.journal.pendingAcks().isEmpty)
        XCTAssertEqual(WatchCaptureImportJournal(directoryURL: fixture.directory).pendingJobs().count, 1)
    }
}

@MainActor
private final class RetryFixture {
    let directory: URL
    let suite = "WatchRetryTests.\(UUID())"
    let envelope: WatchCaptureEnvelope
    var now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var audioURL: URL { directory.appendingPathComponent("\(envelope.id).m4a") }
    static var result: TranscriptionResult {
        .init(text: "Recovered note", segments: [], confidence: nil, duration: 5,
              modelIdentifier: AppleLocalModels.preferredSpeechModelID, cost: nil, rawPayload: nil, debugInfo: nil)
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("watch-retry-\(UUID())")
        envelope = WatchCaptureEnvelope(id: UUID(), createdAt: now, duration: 5, fileExtension: "m4a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: audioURL)
        WatchCaptureImportJournal(directoryURL: directory).parkJobReportingDurability(
            captureID: envelope.id, fileExtension: "m4a", createdAt: now, duration: 5, now: now
        )
    }

    func pipeline() -> WatchCaptureImportPipeline {
        let pipeline = WatchCaptureImportPipeline(inboxDirectory: directory)
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: suite)!, loadsSecureStorage: false,
            credentialStorage: SecureStorage(configuration: .init(service: suite),
                                             permissionsChecker: RetryDeniedPermissions())
        )
        settings.batchTranscriptionModel = AppleLocalModels.preferredSpeechModelID
        settings.autoPostProcess = false
        pipeline.credentialSettings = settings
        pipeline.now = { self.now }
        pipeline.beginBackgroundTask = { _ in .invalid }
        pipeline.persistHistory = { _ in true }
        return pipeline
    }

    func assertRetained(_ pipeline: WatchCaptureImportPipeline) throws {
        XCTAssertEqual(pipeline.journal.pendingJobs().first?.attempts, 0)
        XCTAssertTrue(pipeline.journal.pendingAcks().isEmpty)
        XCTAssertEqual(try Data(contentsOf: audioURL), Data("synthetic audio".utf8))
    }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct RetryDeniedPermissions: KeychainPermissionsChecking {
    func ensureKeychainAccess(forService service: String) async -> Bool { false }
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
