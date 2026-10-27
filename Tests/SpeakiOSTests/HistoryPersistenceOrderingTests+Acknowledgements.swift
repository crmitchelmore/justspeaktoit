#if os(iOS)
import Foundation
import XCTest
@testable import SpeakiOSLib
@testable import SpeakSync

@MainActor
extension HistoryPersistenceOrderingTests {
    func testDirectUploadCallbacksCannotConsumeFullSyncOfferOrAcknowledgeNewerRow() async throws {
        let old = item("old")
        try write([old])
        let firstEntered = expectation(description: "First direct upload held")
        let secondEntered = expectation(description: "Second direct upload held")
        let hold = HistoryUploadHold(entered: [firstEntered, secondEntered])
        defer { hold.releaseAll() }
        let settled = expectation(description: "Both direct wrappers settled")
        settled.expectedFulfillmentCount = 2
        let reference = HistoryManagerReference()
        let manager = makeManager(HistoryAsyncStorage(primary: file), upload: { entry in
            let index = await hold.wait()
            // This is the actual ordering of HistorySyncEngine.upload's delegate callback.
            guard let history = reference.value else { throw CocoaError(.fileReadUnknown) }
            await history.didAcknowledgeSyncedEntries(ids: [entry.id])
            if index == 1 { throw CocoaError(.fileReadUnknown) }
        }, settled: { _ in settled.fulfill() })
        reference.value = manager
        await manager.loadIfNeededAndWait()
        _ = manager.pendingEntries() // Full-sync offer predates both direct writes.
        let first = old.withPostProcessed("one", updatedAt: old.updatedAt.addingTimeInterval(1))
        _ = await manager.upsertAndWait(first)
        guard await completed(firstEntered) else { return }
        let second = old.withPostProcessed("two", updatedAt: old.updatedAt.addingTimeInterval(2))
        _ = await manager.upsertAndWait(second)
        guard await completed(secondEntered) else { return }
        _ = manager.pendingEntries()
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertFalse(manager.isSynced(second))
        hold.releaseAll()
        guard await completed(settled) else { return }
        // The old direct success must not acknowledge v2, whose own upload failed.
        XCTAssertFalse(manager.isSynced(second))
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertFalse(
            manager.isSynced(second), "In-flight direct callbacks must preserve the original full-sync offer"
        )
        _ = manager.pendingEntries()
        await manager.didAcknowledgeSyncedEntries(ids: [old.id])
        XCTAssertTrue(manager.isSynced(second))
    }

    func testActualQueuedSyncUploadsNewRevisionInsteadOfAcceptingOldReceipt() async throws {
        let old = item("old")
        try write([old])
        let manager = iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults)
        let firstEntered = expectation(description: "Old revision upload held")
        let secondEntered = expectation(description: "New revision upload held")
        let hold = HistoryUploadHold(entered: [firstEntered, secondEntered])
        defer { hold.releaseAll() }
        let transport = HistoryHeldUploadTransport(hold: hold)
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: manager
        )
        let finished = expectation(description: "Both sync passes settled")
        let sync = Task { await engine.sync(); finished.fulfill() }
        guard await completed(firstEntered) else { sync.cancel(); return }
        let newer = old.withPostProcessed("new", updatedAt: old.updatedAt.addingTimeInterval(1))
        _ = await manager.upsertAndWait(newer)
        await engine.sync() // Actual status query before the coordinator's isSyncing guard.
        hold.release(0)
        guard await completed(secondEntered) else { sync.cancel(); return }
        XCTAssertFalse(manager.isSynced(newer))
        XCTAssertEqual(transport.uploaded.map { $0.first?.postProcessedText }, [nil, "new"])
        hold.releaseAll()
        guard await completed(finished) else { sync.cancel(); return }
        XCTAssertTrue(manager.isSynced(newer))
        XCTAssertNil(engine.state.error)
    }

}
#endif
