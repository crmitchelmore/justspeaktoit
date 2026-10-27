#if os(iOS)
import Foundation
import XCTest
import UIKit
@testable import SpeakiOSLib

@MainActor
final class HistoryPersistenceAsyncTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("transcription-history.json")
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    func testColdReadSuspensionDoesNotBlockMainActorOrLoseAdmittedAppend() async throws {
        let old = item("old")
        let added = item("new")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        let entered = expectation(description: "Worker entered primary read")
        storage.holdRead(entered)
        defer { storage.release() }
        let manager = manager(storage)
        XCTAssertTrue(manager.items.isEmpty)
        let loaded = expectation(description: "Load settled")
        let load = Task { await manager.loadIfNeededAndWait(); loaded.fulfill() }
        guard await completed(entered) else { load.cancel(); return }
        // This line executes on MainActor while the worker's read is held.
        XCTAssertTrue(manager.isLoading)
        let saved = expectation(description: "Append settled")
        let append = Task { let durable = await manager.upsertAndWait(added); saved.fulfill(); return durable }
        storage.release()
        guard await completed(loaded, saved) else { load.cancel(); append.cancel(); return }
        let appended = await append.value
        XCTAssertTrue(appended)
        XCTAssertEqual(Set(manager.items.map(\.id)), [old.id, added.id])
        XCTAssertEqual(Set(try read().map(\.id)), [old.id, added.id])
        XCTAssertFalse(storage.observedMainThread)
        XCTAssertFalse(storage.timedOut)
    }

    func testWorkerAdmissionOrdersColdLoadAppendClearAndFinalAppend() async throws {
        try write([item("old")])
        let storage = HistoryAsyncStorage(primary: file)
        let entered = expectation(description: "Read held")
        storage.holdRead(entered)
        defer { storage.release() }
        let persistence = IOSHistoryPersistence(fileURL: file, storageIO: storage.storageIO)
        let load = persistence.admit(.load, revision: 1)
        guard await completed(entered) else { return }
        let erased = item("erased")
        let final = item("final")
        let append = persistence.admit(.upsert(erased), revision: 2)
        let clear = persistence.admit(.clear, revision: 3)
        let last = persistence.admit(.upsert(final), revision: 4)
        storage.release()
        let done = expectation(description: "Ordered queue settled")
        let task = Task {
            let results = await [persistence.result(for: load), persistence.result(for: append),
                                 persistence.result(for: clear), persistence.result(for: last)]
            done.fulfill()
            return results
        }
        guard await completed(done) else { task.cancel(); return }
        let results = await task.value
        XCTAssertEqual(results.map(\.revision), [1, 2, 3, 4])
        XCTAssertTrue(results.allSatisfy(\.durable))
        XCTAssertEqual(results.last?.rows.map(\.id), [final.id])
        XCTAssertEqual(try read().map(\.id), [final.id])
        XCTAssertFalse(storage.observedMainThread)
        XCTAssertFalse(storage.timedOut)
    }

    func testOlderAsyncCompletionCannotOverwriteNewerSynchronousPublication() async throws {
        let old = item("old")
        let newer = item("new")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        let entered = expectation(description: "Cold async read held")
        storage.holdRead(entered)
        defer { storage.release() }
        let manager = manager(storage)
        let done = expectation(description: "Older load resumed")
        let load = Task { await manager.loadIfNeededAndWait(); done.fulfill() }
        guard await completed(entered) else { load.cancel(); return }
        // The compatibility call cannot yield MainActor. Release the owned IO
        // hold off actor, then publish revision 2 before revision 1 can resume.
        DispatchQueue.global().async { storage.release() }
        XCTAssertTrue(manager.upsertReportingDurability(newer))
        guard await completed(done) else { load.cancel(); return }
        XCTAssertEqual(Set(manager.items.map(\.id)), [old.id, newer.id])
        XCTAssertEqual(Set(try read().map(\.id)), [old.id, newer.id])
    }

    func testColdDeleteLoadsOtherRowsBeforeRemovingTarget() async throws {
        let removed = item("remove")
        let retained = item("retain")
        try write([removed, retained])
        let manager = manager()
        await manager.removeAndWait(removed)
        XCTAssertEqual(manager.items.map(\.id), [retained.id])
        XCTAssertEqual(try read().map(\.id), [retained.id])
    }

    func testCancelledCallerStillReceivesOwnedDurableWrite() async throws {
        let storage = HistoryAsyncStorage(primary: file)
        let entered = expectation(description: "Write held")
        storage.holdWrite(entered)
        defer { storage.release() }
        let manager = manager(storage)
        let added = item("admitted before cancel")
        let done = expectation(description: "Cancelled caller received receipt")
        let task = Task { let durable = await manager.upsertAndWait(added); done.fulfill(); return durable }
        guard await completed(entered) else { task.cancel(); return }
        task.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        storage.release()
        guard await completed(done) else { return }
        let durable = await task.value
        XCTAssertTrue(durable)
        XCTAssertEqual(try read().map(\.id), [added.id])
    }

    func testWriteFailureNeverReturnsSavedRowAndRetryRetainsPendingText() async throws {
        let old = item("old")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        storage.failWrites = true
        let manager = manager(storage)
        let saved = await manager.recordTranscriptionAndWait(text: "pending", model: "test", duration: 1)
        XCTAssertNil(saved)
        XCTAssertEqual(Set(manager.items.map(\.transcription)), ["old", "pending"])
        XCTAssertEqual(try read().map(\.id), [old.id])
        storage.failWrites = false
        await manager.retryPersistenceAndWait()
        XCTAssertTrue(manager.isStorageReady)
        XCTAssertEqual(Set(try read().map(\.transcription)), ["old", "pending"])
    }

    func testUnreadablePrimaryPreservedWhileAwaitedSidecarIsDurable() async throws {
        let original = Data("preserved corrupt primary".utf8)
        try original.write(to: file)
        let manager = manager()
        let added = item("pending recovery")
        let durable = await manager.upsertAndWait(added)
        XCTAssertTrue(durable)
        XCTAssertFalse(manager.isStorageReady)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let reopened = self.manager()
        await reopened.loadIfNeededAndWait()
        XCTAssertEqual(reopened.items.map(\.id), [added.id])
        XCTAssertFalse(reopened.isStorageReady)
    }

    func testUnreadableSidecarCannotBeOverwrittenByAsyncMutation() async throws {
        let old = item("old")
        try write([old])
        let recovery = file.appendingPathExtension("recovery")
        let original = Data("corrupt sidecar".utf8)
        try original.write(to: recovery)
        let manager = manager()
        let durable = await manager.upsertAndWait(item("memory only"))
        XCTAssertFalse(durable)
        XCTAssertEqual(try Data(contentsOf: recovery), original)
        XCTAssertEqual(try read().map(\.id), [old.id])
        XCTAssertNotNil(manager.persistenceError)
    }

    func testCommittedPrimaryWithFailedCleanupReturnsDurabilityThenRetriesCleanup() async throws {
        let storage = HistoryAsyncStorage(primary: file)
        storage.failRemoval = true
        let manager = manager(storage)
        let added = item("committed")
        let durable = await manager.upsertAndWait(added)
        XCTAssertTrue(durable)
        XCTAssertFalse(manager.isStorageReady)
        XCTAssertEqual(try read().map(\.id), [added.id])
        storage.failRemoval = false
        await manager.retryPersistenceAndWait()
        XCTAssertTrue(manager.isStorageReady)
        XCTAssertNil(manager.persistenceError)
        XCTAssertEqual(try read().map(\.id), [added.id])
    }

}

@MainActor
extension HistoryPersistenceAsyncTests {
    func testColdSameIDFailedMutationDoesNotInheritLoadedRowsDurability() async throws {
        let old = item("old")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        storage.failWrites = true
        let manager = manager(storage)
        let newer = old.withPostProcessed("new", updatedAt: old.updatedAt.addingTimeInterval(1))
        let durable = await manager.upsertAndWait(newer)
        XCTAssertFalse(durable)
        XCTAssertEqual(manager.items.first?.postProcessedTranscription, "new")
        XCTAssertTrue(manager.pendingEntries().isEmpty)
        XCTAssertNil(try read().first?.postProcessedTranscription)
    }

    func testDelayedPolishAfterDeletionDoesNotResurrectRow() async throws {
        let old = item("old")
        try write([old])
        let manager = manager()
        await manager.removeAndWait(old)
        await manager.setPostProcessedAndWait("late result", for: old.id)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(try read().isEmpty)
    }

    func testLateUploadAcknowledgementDoesNotAcknowledgeNewerCommittedRevision() async throws {
        let old = item("old")
        try write([old])
        let manager = manager()
        await manager.loadIfNeededAndWait()
        XCTAssertEqual(manager.pendingEntries().map(\.id), [old.id])
        let newer = old.withPostProcessed("new revision", updatedAt: old.updatedAt.addingTimeInterval(1))
        let durable = await manager.upsertAndWait(newer)
        XCTAssertTrue(durable)
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertFalse(manager.isSynced(newer))
        XCTAssertEqual(manager.pendingEntries().map(\.postProcessedText), ["new revision"])
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertTrue(manager.isSynced(newer))
    }

}

@MainActor
extension HistoryPersistenceAsyncTests {
    func testRemoteAcknowledgementWaitsForSuccessfulDurability() async throws {
        let old = item("old")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        storage.failWrites = true
        let manager = manager(storage)
        await manager.loadIfNeededAndWait()
        let newer = old.withPostProcessed("remote", updatedAt: old.updatedAt.addingTimeInterval(1))
        await manager.didReceiveRemoteEntry(newer.toSyncable())
        XCTAssertFalse(manager.isSynced(newer))
        do {
            try await manager.persistRemoteChanges()
            XCTFail("Failed stores cannot acknowledge remote changes")
        } catch { XCTAssertFalse(manager.isSynced(newer)) }
        storage.failWrites = false
        try await manager.persistRemoteChanges()
        XCTAssertTrue(manager.isSynced(newer))
        XCTAssertEqual(try read().first?.postProcessedTranscription, "remote")
    }

    func testFailedAsyncDeletionPreservesRowAndNotificationClaims() async throws {
        let old = item("old")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        storage.failWrites = true
        var retired: Set<UUID> = []
        let manager = iOSHistoryManager(
            fileURL: file, syncEnabled: false, userDefaults: defaults, storageIO: storage.storageIO,
            loadImmediately: false, removeNotificationClaims: { retired.formUnion($0) }
        )
        await manager.removeAndWait(old)
        XCTAssertEqual(manager.items.map(\.id), [old.id])
        XCTAssertTrue(retired.isEmpty)
        storage.failWrites = false
        await manager.retryPersistenceAndWait()
        await manager.removeAndWait(old)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertEqual(retired, [old.id])
    }

    func testPolishCancellationRetainsCleanupOwnershipUntilAdmittedWriteSettles() async throws {
        let old = item("raw")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        let manager = manager(storage)
        await manager.loadIfNeededAndWait()
        let entered = expectation(description: "Polish history write held")
        storage.holdWrite(entered)
        defer { storage.release() }
        var completions = 0
        var ends = 0
        let finished = expectation(description: "Polish cleanup after receipt")
        let assertion = BackgroundTaskAssertion(
            name: "History test", begin: { _, _ in UIBackgroundTaskIdentifier(rawValue: 42) },
            end: { _ in ends += 1 }
        )
        let operation = AutomaticPolishOperation(
            isCurrent: { true },
            successAndWait: { text, _ in await manager.setPostProcessedAndWait(text, for: old.id) },
            failureAndWait: { _ in XCTFail("Unexpected provider failure") },
            completion: { completions += 1; assertion.end(); finished.fulfill() }
        )
        defer { operation.cancel() }
        operation.start(under: assertion, isActive: true) { "polished" }
        guard await completed(entered) else { return }
        operation.cancel()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(ends, 0)
        storage.release()
        guard await completed(finished) else { return }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(try read().first?.postProcessedTranscription, "polished")
    }

    private func manager(_ storage: HistoryAsyncStorage? = nil) -> iOSHistoryManager {
        iOSHistoryManager(
            fileURL: file, syncEnabled: false, userDefaults: defaults,
            storageIO: storage?.storageIO ?? .init(), loadImmediately: false
        )
    }

    private func item(_ text: String) -> iOSHistoryItem {
        iOSHistoryItem(transcription: text, model: "test", duration: 1, wordCount: 1)
    }

    private func write(_ rows: [iOSHistoryItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rows).write(to: file, options: .atomic)
    }

    private func read() throws -> [iOSHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([iOSHistoryItem].self, from: Data(contentsOf: file))
    }

    private func completed(_ expectations: XCTestExpectation...) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 2)
        if result != .completed { XCTFail("History worker did not settle within its bounded fixture wait") }
        return result == .completed
    }
}
#endif
