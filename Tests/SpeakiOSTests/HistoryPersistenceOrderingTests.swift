#if os(iOS)
import Foundation
@testable import SpeakSync
import XCTest
@testable import SpeakiOSLib

@MainActor
final class HistoryPersistenceOrderingTests: XCTestCase {
    var directory: URL!
    var file: URL!
    var defaults: UserDefaults!
    var suite: String!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("history.json")
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    func testUnrelatedLaterAdmissionDoesNotSuppressOwnedDurableUpload() async throws {
        let storage = HistoryAsyncStorage(primary: file)
        var uploaded: [UUID] = []
        let uploads = expectation(description: "Both owned uploads")
        uploads.expectedFulfillmentCount = 2
        let manager = makeManager(storage, upload: { uploaded.append($0.id); uploads.fulfill() })
        await manager.loadIfNeededAndWait()
        let entered = expectation(description: "First write held")
        storage.holdWrite(entered)
        defer { storage.release() }
        let first = item("first")
        let second = item("second")
        let firstDone = expectation(description: "First receipt")
        let firstTask = Task { let result = await manager.upsertAndWait(first); firstDone.fulfill(); return result }
        guard await completed(entered) else { firstTask.cancel(); return }
        let admitted = expectation(description: "Second task admitted before release")
        let secondDone = expectation(description: "Second receipt")
        let secondTask = Task {
            // No suspension between this signal and upsert's synchronous admission.
            admitted.fulfill()
            let result = await manager.upsertAndWait(second)
            secondDone.fulfill()
            return result
        }
        guard await completed(admitted) else { firstTask.cancel(); secondTask.cancel(); return }
        storage.release()
        guard await completed(firstDone, secondDone, uploads) else { return }
        let receipts = await [firstTask.value, secondTask.value]
        XCTAssertTrue(receipts.allSatisfy { $0 })
        XCTAssertEqual(Set(uploaded), [first.id, second.id])
        XCTAssertEqual(Set(manager.items.map(\.id)), [first.id, second.id])
    }

    func testUnrelatedLaterAdmissionDoesNotSuppressOwnedRemovalEffects() async throws {
        let removed = item("remove")
        try write([removed])
        let storage = HistoryAsyncStorage(primary: file)
        var retired: Set<UUID> = []
        var deleted: [UUID] = []
        let deletion = expectation(description: "Owned remote deletion")
        let manager = makeManager(storage, delete: { deleted.append($0); deletion.fulfill() },
                                  retire: { retired.formUnion($0) })
        await manager.loadIfNeededAndWait()
        let entered = expectation(description: "Removal write held")
        storage.holdWrite(entered)
        defer { storage.release() }
        let removedDone = expectation(description: "Removal receipt")
        let remove = Task { await manager.removeAndWait(removed); removedDone.fulfill() }
        guard await completed(entered) else { remove.cancel(); return }
        let admitted = expectation(description: "Unrelated append admitted")
        let appended = expectation(description: "Unrelated append settled")
        let other = item("other")
        let append = Task {
            admitted.fulfill()
            _ = await manager.upsertAndWait(other)
            appended.fulfill()
        }
        guard await completed(admitted) else { remove.cancel(); append.cancel(); return }
        storage.release()
        guard await completed(removedDone, appended, deletion) else { return }
        XCTAssertEqual(retired, [removed.id])
        XCTAssertEqual(deleted, [removed.id])
        XCTAssertEqual(manager.items.map(\.id), [other.id])
    }

    func testSameIDReinsertionProtectsNewClaimsAndRowFromOldRemovalEffects() async throws {
        let old = item("old")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        var retired: Set<UUID> = []
        var deleted: Set<UUID> = []
        let manager = makeManager(storage, delete: { deleted.insert($0) }, retire: { retired.formUnion($0) })
        await manager.loadIfNeededAndWait()
        let entered = expectation(description: "Removal held")
        storage.holdWrite(entered)
        defer { storage.release() }
        let removed = expectation(description: "Removal settled")
        let removal = Task { await manager.removeAndWait(old); removed.fulfill() }
        guard await completed(entered) else { removal.cancel(); return }
        let admitted = expectation(description: "Reinsertion admitted")
        let inserted = expectation(description: "Reinsertion settled")
        let replacement = old.withPostProcessed("replacement", updatedAt: old.updatedAt.addingTimeInterval(1))
        let insertion = Task {
            admitted.fulfill()
            _ = await manager.upsertAndWait(replacement)
            inserted.fulfill()
        }
        guard await completed(admitted) else { removal.cancel(); insertion.cancel(); return }
        storage.release()
        guard await completed(removed, inserted) else { return }
        XCTAssertTrue(retired.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(manager.items.first?.postProcessedTranscription, "replacement")
    }

    func testLaterClearPreventsSupersededUpsertUpload() async throws {
        let storage = HistoryAsyncStorage(primary: file)
        var uploads = 0
        let manager = makeManager(storage, upload: { _ in uploads += 1 })
        await manager.loadIfNeededAndWait()
        let entered = expectation(description: "Upsert held")
        storage.holdWrite(entered)
        defer { storage.release() }
        let saved = expectation(description: "Upsert settled")
        let save = Task { _ = await manager.upsertAndWait(item("erased")); saved.fulfill() }
        guard await completed(entered) else { save.cancel(); return }
        let admitted = expectation(description: "Clear admitted")
        let cleared = expectation(description: "Clear settled")
        let clear = Task { admitted.fulfill(); await manager.clearAllAndWait(); cleared.fulfill() }
        guard await completed(admitted) else { save.cancel(); clear.cancel(); return }
        storage.release()
        guard await completed(saved, cleared) else { return }
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(try read().isEmpty)
    }

    func testLocalDeleteAndClearRecoveryContainTheirOwnTombstones() async throws {
        for clearsAll in [false, true] {
            let old = item("old")
            try write([old])
            let storage = HistoryAsyncStorage(primary: file)
            let manager = makeManager(storage)
            await manager.loadIfNeededAndWait()
            let remote = item("remote")
            await manager.didReceiveRemoteEntry(remote.toSyncable())
            storage.failPrimaryWrites = true
            if clearsAll { await manager.clearAllAndWait() } else { await manager.removeAndWait(old) }
            await manager.flushPendingChangesAndWait()
            let reopened = iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults)
            XCTAssertFalse(reopened.items.contains { $0.id == old.id })
            XCTAssertEqual(reopened.items.contains { $0.id == remote.id }, !clearsAll)
        }
    }

}
@MainActor
extension HistoryPersistenceOrderingTests {
    func testFailedLocalDeletionRestoresIntentBeforeRetryingUnrelatedRemoteRow() async throws {
        let old = item("old")
        try write([old])
        let storage = HistoryAsyncStorage(primary: file)
        let manager = makeManager(storage)
        await manager.loadIfNeededAndWait()
        let remote = item("remote")
        await manager.didReceiveRemoteEntry(remote.toSyncable())
        storage.failWrites = true
        await manager.removeAndWait(old)
        XCTAssertTrue(manager.items.contains { $0.id == old.id })
        storage.failWrites = false
        await manager.retryPersistenceAndWait()
        let reopened = iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults)
        XCTAssertEqual(Set(reopened.items.map(\.id)), [old.id, remote.id])
    }

    func testOverlappingStatusQueryCannotRebindOldAcknowledgementToNewRevision() async throws {
        let old = item("old")
        try write([old])
        let manager = iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults)
        _ = manager.pendingEntries()
        let newer = old.withPostProcessed("new", updatedAt: old.updatedAt.addingTimeInterval(1))
        let durable = await manager.upsertAndWait(newer)
        XCTAssertTrue(durable)
        _ = manager.pendingEntries() // The queued-sync/status call must not replace the first offer.
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertFalse(manager.isSynced(newer))
        _ = manager.pendingEntries()
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertTrue(manager.isSynced(newer))
    }

    func testUnofferedGenericAcknowledgementCannotClaimCurrentRow() async throws {
        let old = item("old")
        try write([old])
        let manager = iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults)
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertFalse(manager.isSynced(old))
    }

}
@MainActor
extension HistoryPersistenceOrderingTests {
    func testConcurrentRetriesAndAppendPreserveRecoveryAndPrimaryRows() async throws {
        try Data("unreadable original".utf8).write(to: file)
        let storage = HistoryAsyncStorage(primary: file)
        let manager = iOSHistoryManager(
            fileURL: file, syncEnabled: false, userDefaults: defaults, storageIO: storage.storageIO
        )
        let recovered = item("recovery")
        XCTAssertTrue(manager.upsertReportingDurability(recovered))
        let old = item("old")
        try write([old])
        let entered = expectation(description: "Retry read held")
        storage.holdRead(entered)
        defer { storage.release() }
        let firstDone = expectation(description: "First retry settled")
        let first = Task { await manager.retryPersistenceAndWait(); firstDone.fulfill() }
        guard await completed(entered) else { first.cancel(); return }
        let admitted = expectation(description: "Append admitted during retry")
        let lastDone = expectation(description: "Append and second retry settled")
        let new = item("new")
        let last = Task {
            admitted.fulfill()
            _ = await manager.upsertAndWait(new)
            await manager.retryPersistenceAndWait()
            lastDone.fulfill()
        }
        guard await completed(admitted) else { first.cancel(); last.cancel(); return }
        storage.release()
        guard await completed(firstDone, lastDone) else { first.cancel(); last.cancel(); return }
        XCTAssertEqual(Set(try read().map(\.id)), [old.id, recovered.id, new.id])
        XCTAssertEqual(Set(manager.items.map(\.id)), [old.id, recovered.id, new.id])
        XCTAssertTrue(manager.isStorageReady)
    }

    func testLaterRemoteAdmissionRemainsPendingAfterEarlierCommit() async throws {
        let storage = HistoryAsyncStorage(primary: file)
        let manager = makeManager(storage)
        await manager.loadIfNeededAndWait()
        let first = item("first remote")
        await manager.didReceiveRemoteEntry(first.toSyncable())
        let entered = expectation(description: "First remote commit held")
        storage.holdWrite(entered)
        defer { storage.release() }
        let firstDone = expectation(description: "First commit settled")
        let commit = Task {
            do { try await manager.persistRemoteChanges() } catch { XCTFail("Unexpected commit failure") }
            firstDone.fulfill()
        }
        guard await completed(entered) else { commit.cancel(); return }
        let admitted = expectation(description: "Later remote admitted")
        let laterDone = expectation(description: "Later remote remembered")
        let later = item("later remote")
        let receive = Task {
            admitted.fulfill()
            await manager.didReceiveRemoteEntry(later.toSyncable())
            laterDone.fulfill()
        }
        guard await completed(admitted) else { commit.cancel(); receive.cancel(); return }
        storage.release()
        guard await completed(firstDone, laterDone) else { commit.cancel(); receive.cancel(); return }
        XCTAssertFalse(manager.isSynced(later))
        try await manager.persistRemoteChanges()
        XCTAssertTrue(manager.isSynced(later))
        XCTAssertEqual(Set(try read().map(\.id)), [first.id, later.id])
    }

    func testReadyLoadAndMissingRowUpdatesCannotPromoteUncommittedRemoteVersion() async throws {
        let storage = HistoryAsyncStorage(primary: file)
        let manager = makeManager(storage)
        await manager.loadIfNeededAndWait()
        let remote = item("not committed yet")
        await manager.didReceiveRemoteEntry(remote.toSyncable())
        await manager.loadIfNeededAndWait()
        await manager.setPostProcessedAndWait("missing", for: UUID())
        await manager.setErrorAndWait("missing", for: UUID())
        XCTAssertTrue(manager.pendingEntries().isEmpty)
        XCTAssertFalse(manager.isSynced(remote))
        XCTAssertTrue(try read().isEmpty)
        storage.failWrites = true
        do {
            try await manager.persistRemoteChanges()
            XCTFail("Uncommitted row cannot acquire durability from a ready load")
        } catch { XCTAssertFalse(manager.isSynced(remote)) }
        storage.failWrites = false
        try await manager.persistRemoteChanges()
        XCTAssertTrue(manager.isSynced(remote))
        XCTAssertEqual(try read().map(\.id), [remote.id])
    }

    func makeManager(
        _ storage: HistoryAsyncStorage,
        upload: @escaping @MainActor (SyncableHistoryEntry) async throws -> Void = { _ in },
        delete: @escaping @MainActor (UUID) async throws -> Void = { _ in },
        retire: @escaping (Set<UUID>) -> Void = { _ in },
        settled: @escaping @MainActor (UUID) -> Void = { _ in }
    ) -> iOSHistoryManager {
        iOSHistoryManager(
            fileURL: file, syncEnabled: true, userDefaults: defaults, storageIO: storage.storageIO,
            startSync: { _ in }, loadImmediately: false, uploadEntry: upload, deleteEntry: delete,
            uploadSettled: settled, removeNotificationClaims: retire
        )
    }

    func item(_ text: String) -> iOSHistoryItem {
        iOSHistoryItem(transcription: text, model: "test", duration: 1, wordCount: 1)
    }

    func write(_ rows: [iOSHistoryItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rows).write(to: file, options: .atomic)
    }

    func read() throws -> [iOSHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([iOSHistoryItem].self, from: Data(contentsOf: file))
    }

    func completed(
        _ expectations: XCTestExpectation..., file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 2)
        if result != .completed { XCTFail("Ordered History operation did not settle", file: file, line: line) }
        return result == .completed
    }
}
#endif
