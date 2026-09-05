#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class WatchCaptureOrphanRetentionTests: XCTestCase {
    func testFailedJournalPark_retainsFreshArrivalThenSweepsOrphanAfterRelaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = WatchCaptureImportPipeline(inboxDirectory: directory)
        let journalURL = directory.appendingPathComponent("import-journal.json")
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        let envelope = WatchCaptureEnvelope(duration: 5)
        let source = directory.appendingPathComponent("incoming.m4a")
        try Data([1, 2, 3]).write(to: source)
        let expired = Date().addingTimeInterval(-WatchCaptureImportJournal.defaultRetentionInterval - 60)
        try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: source.path)
        let arrival = Date()
        XCTAssertFalse(pipeline.parkDeliveredFile(at: source, envelope: envelope))
        let parked = directory.appendingPathComponent("\(envelope.id.uuidString).m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
        XCTAssertTrue(pipeline.journal.pendingJobs().isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: parked.path)
        let modifiedAt = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertGreaterThanOrEqual(modifiedAt.timeIntervalSince1970, arrival.timeIntervalSince1970 - 1)

        try FileManager.default.removeItem(at: journalURL)
        let relaunched = WatchCaptureImportPipeline(inboxDirectory: directory)
        await relaunched.processPendingImports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
        try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: parked.path)
        await relaunched.processPendingImports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(relaunched.journal.pendingAcks().isEmpty)
    }

    func testOrphanSweep_preservesJournalReferencesFreshAudioAndUnrelatedEntries() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = WatchCaptureImportPipeline(inboxDirectory: directory)
        let pending = UUID()
        let acknowledged = UUID()
        let expired = Date().addingTimeInterval(-WatchCaptureImportJournal.defaultRetentionInterval - 60)
        let orphan = try writeAudio(in: directory, modifiedAt: expired)
        let pendingAudio = try writeAudio(in: directory, captureID: pending, modifiedAt: expired)
        let ackAudio = try writeAudio(in: directory, captureID: acknowledged, modifiedAt: expired)
        let fresh = try writeAudio(in: directory, modifiedAt: Date())
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data([4]).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: unrelated.path)
        let subdirectory = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: subdirectory.path)
        pipeline.journal.parkJob(captureID: pending, fileExtension: "m4a", createdAt: Date(), duration: 5)
        pipeline.journal.recordPendingAck(WatchCaptureAckRecord(captureID: acknowledged, outcome: .failed))

        pipeline.purgeOrphanedAudio()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        for preserved in [pendingAudio, ackAudio, fresh, unrelated, subdirectory] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path), preserved.lastPathComponent)
        }
        XCTAssertEqual(pipeline.journal.pendingJobs().map(\.captureID), [pending])
        XCTAssertEqual(pipeline.journal.pendingAcks().map(\.captureID), [acknowledged])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-orphan-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAudio(in directory: URL, captureID: UUID = UUID(), modifiedAt: Date) throws -> URL {
        let file = directory.appendingPathComponent("\(captureID.uuidString).m4a")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }
}
#endif
