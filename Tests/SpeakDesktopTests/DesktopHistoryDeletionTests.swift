import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopHistoryDeletionTests: XCTestCase {
    private func makeStore() throws -> (URL, DesktopRecordingStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, try DesktopRecordingStore(directory: root))
    }

    private func record(id: UUID = UUID()) -> DesktopRecordingStore.Record {
        DesktopRecordingStore.Record(id: id, audioFilename: id.uuidString + ".wav", modelIdentifier: "test")
    }

    func testDelete_RemovesOwnedFilesAndRejectsLateSaveAfterRelaunch() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record()
        try await store.save(recording)
        let audio = root.appendingPathComponent(recording.audioFilename)
        try Data([1, 2, 3]).write(to: audio)
        try await store.delete(id: recording.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            recording.id.uuidString + ".json"
        ).path))
        let reopened = try DesktopRecordingStore(directory: root)
        let deleted = await reopened.isDeleted(id: recording.id)
        XCTAssertTrue(deleted)
        let remaining = try await reopened.records()
        XCTAssertTrue(remaining.isEmpty)
        do {
            try await reopened.save(recording)
            XCTFail("A late transcription recreated deleted History")
        } catch { XCTAssertEqual(error as? DesktopHistoryDeletionError, .recordDeleted(recording.id)) }
        do {
            _ = try await reopened.audioURL(for: recording)
            XCTFail("A stale playback snapshot resolved deleted audio")
        } catch { XCTAssertEqual(error as? DesktopHistoryDeletionError, .recordDeleted(recording.id)) }
    }

    func testJournalFailure_LeavesAudioMetadataAndVisibilityUnchanged() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record()
        try await store.save(recording)
        let audio = root.appendingPathComponent(recording.audioFilename)
        try Data([1, 2]).write(to: audio)
        try FileManager.default.createDirectory(
            at: DesktopHistoryDeletionLedger.url(in: root), withIntermediateDirectories: false
        )
        do {
            try await store.delete(id: recording.id)
            XCTFail("Deletion proceeded without durable intent")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2]))
        let saved = try await store.record(id: recording.id)
        XCTAssertEqual(saved.id, recording.id)
        let deleted = await store.isDeleted(id: recording.id)
        XCTAssertFalse(deleted)
    }

    func testPersistedIntent_HidesRetainedFilesAndResumesCleanup() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record()
        try await store.save(recording)
        let audio = root.appendingPathComponent(recording.audioFilename)
        try Data([9]).write(to: audio)
        var ledger = DesktopHistoryDeletionLedger()
        ledger.intents[recording.id] = .init(
            id: recording.id, revision: UUID(), audioFilename: recording.audioFilename,
            account: "account-A", localCleanupPending: true, cloudPending: true
        )
        try ledger.save(in: root)
        let reopened = try DesktopRecordingStore(directory: root)
        let visible = try await reopened.records()
        let readable = try await reopened.readableRecords()
        let recovery = try await reopened.recoverInterruptedRecordings()
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(readable.isEmpty)
        XCTAssertTrue(recovery.records.isEmpty)
        try await reopened.resumePendingDeletions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        let pending = await reopened.pendingCloudDeletions(account: "account-A")
        XCTAssertEqual(pending.map(\.id), [recording.id])
        try await reopened.resumePendingDeletions()
        let afterRetry = await reopened.pendingCloudDeletions(account: "account-A")
        XCTAssertEqual(afterRetry, pending)
    }

    func testCloudOutbox_IsAccountBoundAndAcknowledgementKeepsLocalSuppression() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record()
        try await store.save(recording)
        try await store.delete(id: recording.id, cloudAccount: "account-A")
        let accountA = await store.pendingCloudDeletions(account: "account-A")
        let accountB = await store.pendingCloudDeletions(account: "account-B")
        XCTAssertEqual(accountA.count, 1)
        XCTAssertTrue(accountB.isEmpty)
        let attempt = try XCTUnwrap(accountA.first)
        try await store.acknowledgeCloudDeletion(.init(
            id: attempt.id, account: "account-B", revision: attempt.revision
        ))
        try await store.acknowledgeCloudDeletion(.init(id: attempt.id, account: attempt.account, revision: UUID()))
        let unchanged = await store.pendingCloudDeletions(account: "account-A")
        XCTAssertEqual(unchanged, accountA)
        try await store.acknowledgeCloudDeletion(attempt)
        let reopened = try DesktopRecordingStore(directory: root)
        let acknowledged = await reopened.pendingCloudDeletions(account: "account-A")
        let deleted = await reopened.isDeleted(id: recording.id)
        XCTAssertTrue(acknowledged.isEmpty)
        XCTAssertTrue(deleted)
        try await reopened.requeueCloudDeletion(id: recording.id, account: "account-A")
        let requeued = await reopened.pendingCloudDeletions(account: "account-A")
        XCTAssertEqual(requeued.count, 1)
        XCTAssertNotEqual(requeued.first?.revision, attempt.revision)
        try await reopened.acknowledgeCloudDeletion(attempt)
        let afterStaleAcknowledgement = await reopened.pendingCloudDeletions(account: "account-A")
        XCTAssertEqual(afterStaleAcknowledgement, requeued)
    }

    func testMissingAudioAndRepeatedDelete_AreIdempotent() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record()
        try await store.save(recording)
        try await store.delete(id: recording.id)
        try await store.delete(id: recording.id)
        let reopened = try DesktopRecordingStore(directory: root)
        try await reopened.resumePendingDeletions()
        let visible = try await reopened.records()
        XCTAssertTrue(visible.isEmpty)
    }

    func testSharedAudio_IsRetainedAndBothRecordsRemainVisible() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = record()
        let second = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: first.audioFilename, modelIdentifier: "test"
        )
        try await store.save(first)
        try await store.save(second)
        let audio = root.appendingPathComponent(first.audioFilename)
        try Data([3]).write(to: audio)
        do {
            try await store.delete(id: first.id)
            XCTFail("Deleted another record's shared audio")
        } catch { XCTAssertEqual(error as? DesktopHistoryDeletionError, .audioOwnershipUnclear) }
        let visible = try await store.records()
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(try Data(contentsOf: audio), Data([3]))
    }

    func testTraversalAndMismatchedMetadata_AreRefusedBeforeJournaling() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "../outside.wav", modelIdentifier: "test"
        )
        try await store.save(recording)
        do {
            try await store.delete(id: recording.id)
            XCTFail("Accepted unsafe deletion path")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        let foreignID = UUID()
        try JSONEncoder().encode(recording).write(to: root.appendingPathComponent(foreignID.uuidString + ".json"))
        do {
            try await store.delete(id: foreignID)
            XCTFail("Removed mismatched metadata")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: DesktopHistoryDeletionLedger.url(in: root).path))
    }

    func testChangedAudioAfterInterruptedDelete_LeavesReplacementFilesUntouched() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record()
        try await store.save(recording)
        var ledger = DesktopHistoryDeletionLedger()
        ledger.intents[recording.id] = .init(
            id: recording.id, revision: UUID(), audioFilename: recording.audioFilename,
            account: nil, localCleanupPending: true, cloudPending: false
        )
        try ledger.save(in: root)
        let replacement = DesktopRecordingStore.Record(
            id: recording.id, audioFilename: "replacement.wav", modelIdentifier: "test"
        )
        let metadata = root.appendingPathComponent(recording.id.uuidString + ".json")
        try JSONEncoder().encode(replacement).write(to: metadata)
        let replacementAudio = root.appendingPathComponent(replacement.audioFilename)
        try Data([7]).write(to: replacementAudio)
        let reopened = try DesktopRecordingStore(directory: root)
        do {
            try await reopened.resumePendingDeletions()
            XCTFail("Removed externally replaced audio")
        } catch { XCTAssertEqual(error as? DesktopHistoryDeletionError, .changedAudioOwnership) }
        XCTAssertEqual(try Data(contentsOf: replacementAudio), Data([7]))
        XCTAssertEqual(try JSONDecoder().decode(DesktopRecordingStore.Record.self, from: Data(
            contentsOf: metadata
        )).audioFilename, replacement.audioFilename)
    }

    func testCorruptOrFutureJournal_FailsClosedOnRelaunch() throws {
        let (root, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = DesktopHistoryDeletionLedger.url(in: root)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try DesktopRecordingStore(directory: root)) {
            XCTAssertEqual($0 as? DesktopHistoryDeletionError, .invalidJournal)
        }
        var ledger = DesktopHistoryDeletionLedger()
        ledger.version = 2
        try JSONEncoder().encode(ledger).write(to: url)
        XCTAssertThrowsError(try DesktopRecordingStore(directory: root)) {
            XCTAssertEqual($0 as? DesktopHistoryDeletionError, .invalidJournal)
        }
    }

}

extension DesktopHistoryDeletionTests {
    func testLinkedAudioAndJournal_AreRefusedWithoutTouchingTheirTargets() async throws {
        #if os(Windows)
        throw XCTSkip("Creating symbolic links requires a separately authorized Windows capability.")
        #else
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record()
        try await store.save(recording)
        let target = root.appendingPathComponent("target.bin")
        try Data([4]).write(to: target)
        let audio = root.appendingPathComponent(recording.audioFilename)
        for destination in [target, root.appendingPathComponent("missing-target")] {
            try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: destination)
            do {
                try await store.delete(id: recording.id)
                XCTFail("Deletion accepted linked audio")
            } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
            try FileManager.default.removeItem(at: audio)
        }
        let journal = DesktopHistoryDeletionLedger.url(in: root)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: target)
        XCTAssertThrowsError(try DesktopRecordingStore(directory: root))
        XCTAssertEqual(try Data(contentsOf: target), Data([4]))
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(
            at: journal, withDestinationURL: root.appendingPathComponent("missing")
        )
        XCTAssertThrowsError(try DesktopRecordingStore(directory: root))
        #endif
    }

    func testDuplicateIdentityWithDifferentAudio_IsRefusedBeforeJournaling() async throws {
        #if os(Windows) || os(macOS)
        throw XCTSkip("Requires a case-sensitive directory for distinct UUID spellings.")
        #else
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = record(id: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")))
        try await store.save(recording)
        let other = DesktopRecordingStore.Record(
            id: recording.id, audioFilename: "other.wav", modelIdentifier: "test"
        )
        try JSONEncoder().encode(other).write(to: root.appendingPathComponent(
            recording.id.uuidString.lowercased() + ".json"
        ))
        do {
            try await store.delete(id: recording.id)
            XCTFail("Journaled ambiguous audio ownership")
        } catch { XCTAssertEqual(error as? DesktopHistoryDeletionError, .changedAudioOwnership) }
        let deleted = await store.isDeleted(id: recording.id)
        XCTAssertFalse(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DesktopHistoryDeletionLedger.url(in: root).path))
        #endif
    }

    func testInterruptedCleanup_ContinuesOtherIntentsAndReportsTheFailedOne() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = record()
        let second = record()
        try await store.save(first)
        try await store.save(second)
        var ledger = DesktopHistoryDeletionLedger()
        for recording in [first, second] {
            ledger.intents[recording.id] = .init(
                id: recording.id, revision: UUID(), audioFilename: recording.audioFilename,
                account: nil, localCleanupPending: true, cloudPending: false
            )
        }
        try ledger.save(in: root)
        let replacement = DesktopRecordingStore.Record(
            id: first.id, audioFilename: "changed.wav", modelIdentifier: "test"
        )
        try JSONEncoder().encode(replacement).write(to: root.appendingPathComponent(first.id.uuidString + ".json"))
        let reopened = try DesktopRecordingStore(directory: root)
        do {
            try await reopened.resumePendingDeletions()
            XCTFail("Cleanup concealed an ownership failure")
        } catch { XCTAssertEqual(error as? DesktopHistoryDeletionError, .changedAudioOwnership) }
        let persisted = try DesktopHistoryDeletionLedger.load(from: root)
        XCTAssertEqual(persisted.intents[first.id]?.localCleanupPending, true)
        XCTAssertEqual(persisted.intents[second.id]?.localCleanupPending, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            second.id.uuidString + ".json"
        ).path))
    }
}
