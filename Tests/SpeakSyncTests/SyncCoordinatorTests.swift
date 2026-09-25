import Foundation
import SpeakCore
import XCTest

@testable import SpeakSync

/// The shared reconciliation, driven the way a desktop host drives it: from
/// its own actor, with no main actor or run loop.
final class SyncCoordinatorTests: XCTestCase {
    /// A pass holds one page at a time: it coalesces the page, applies and
    /// commits it, and saves that page's cursor before fetching the next, so
    /// a long feed neither accumulates in memory nor loses what it applied.
    func testEachPageIsAppliedAndCommittedBeforeItsCursorIsSavedAndTheNextPageFetched() async throws {
        let deleted = SyncWireFixture.entry(raw: "delete me")
        let duplicateID = UUID()
        let older = SyncWireFixture.entry(id: duplicateID, raw: "old", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = SyncWireFixture.entry(id: duplicateID, raw: "new", updatedAt: Date(timeIntervalSince1970: 20))
        let transport = FakeHistoryTransport(pages: [
            page([.changed(deleted), .changed(older), .changed(newer)], token: "p1", moreComing: true),
            page([.deleted(deleted.id)], token: "p2", moreComing: false)
        ])
        let store = FakeHistoryStore(entries: [deleted])
        await transport.logFetches(into: store)
        let cursor = OrderedCursorStore(token: nil, loggingInto: store)
        let host = HistoryHost(transport: transport, tokens: cursor)

        await host.sync(store: store)

        let tokens = await transport.requestedTokens
        XCTAssertEqual(tokens, [nil, Data("p1".utf8)])
        let saves = await cursor.saves
        XCTAssertEqual(saves, [Data("p1".utf8), Data("p2".utf8)])
        let log = await store.log
        XCTAssertEqual(log, [
            "fetch", "receive", "receive", "commit", "save-cursor",
            "fetch", "delete", "commit", "save-cursor"
        ])
        // Within a page only the final event per record is applied; across
        // pages each is applied in feed order, so a later tombstone still wins.
        let received = await store.received
        XCTAssertEqual(received.map(\.rawTranscription), ["delete me", "new"])
        let deletedIDs = await store.deletedIDs
        XCTAssertEqual(deletedIDs, [deleted.id])
        let stored = await store.storedIDs
        XCTAssertEqual(stored, [duplicateID])
        let error = await host.errorDescription
        XCTAssertNil(error)
    }

    /// Progress is durable page by page: a pass that fails on a later page
    /// keeps the pages it committed, and the next pass resumes after them. The
    /// failing page is not applied, and no cursor is saved ahead of it.
    func testAPassThatFailsOnALaterPageResumesAfterTheLastCommittedPage() async throws {
        let first = SyncWireFixture.entry(raw: "page one")
        let unconfirmed = SyncWireFixture.entry(raw: "page without a cursor")
        let transport = FakeHistoryTransport(pages: [
            page([.changed(first)], token: "p1", moreComing: true),
            HistoryChangePage(changes: [.changed(unconfirmed)], serverChangeTokenData: nil, moreComing: true),
            page([.changed(unconfirmed)], token: "p2", moreComing: false)
        ])
        let store = FakeHistoryStore(entries: [])
        let cursor = OrderedCursorStore(token: nil, loggingInto: store)
        let host = HistoryHost(transport: transport, tokens: cursor)

        await host.sync(store: store)

        let failure = await host.errorDescription
        XCTAssertEqual(failure, String(describing: SyncError.invalidChangePage))
        let committed = await cursor.saves
        XCTAssertEqual(committed, [Data("p1".utf8)])
        let appliedFirst = await store.received.map(\.id)
        XCTAssertEqual(appliedFirst, [first.id])

        await host.sync(store: store)

        let tokens = await transport.requestedTokens
        XCTAssertEqual(tokens, [nil, Data("p1".utf8), Data("p1".utf8)])
        let saves = await cursor.saves
        XCTAssertEqual(saves, [Data("p1".utf8), Data("p2".utf8)])
        let applied = await store.received.map(\.id)
        XCTAssertEqual(applied, [first.id, unconfirmed.id])
        let error = await host.errorDescription
        XCTAssertNil(error)
    }

    func testFailedCommitKeepsTheCursorSoTheNextPassReplays() async throws {
        let changed = SyncWireFixture.entry(raw: "changed")
        let replayed = page([.changed(changed)], token: "next", moreComing: false)
        let transport = FakeHistoryTransport(pages: [replayed, replayed])
        let store = FakeHistoryStore(entries: [])
        await store.failCommits(true)
        let cursor = OrderedCursorStore(token: Data("old".utf8))
        let host = HistoryHost(transport: transport, tokens: cursor)

        await host.sync(store: store)
        let failedSaves = await cursor.saves
        XCTAssertTrue(failedSaves.isEmpty)
        let failure = await host.errorDescription
        XCTAssertNotNil(failure)

        await store.failCommits(false)
        await host.sync(store: store)
        let tokens = await transport.requestedTokens
        XCTAssertEqual(tokens, [Data("old".utf8), Data("old".utf8)])
        let saves = await cursor.saves
        XCTAssertEqual(saves, [Data("next".utf8)])
    }

    func testATriggerDuringAPassRunsAFollowUpPass() async throws {
        let transport = FakeHistoryTransport(pages: [])
        let store = FakeHistoryStore(entries: [])
        let host = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil))
        await transport.setOnFetch { await host.sync(store: store) }

        await host.sync(store: store)

        let fetches = await transport.requestedTokens.count
        XCTAssertEqual(fetches, 2, "the trigger observed during the first pass must produce a second one")
        let syncing = await host.isSyncing
        XCTAssertFalse(syncing)
    }

    func testAStoreThatNeverAcknowledgesFailsInsteadOfLooping() async throws {
        let entry = SyncWireFixture.entry()
        let transport = FakeHistoryTransport(pages: [])
        let store = FakeHistoryStore(entries: [entry], acknowledges: false)
        let host = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil))

        await host.sync(store: store)

        let error = await host.errorDescription
        XCTAssertEqual(error, String(describing: SyncError.reconciliationIncomplete(1)))
        let batches = await transport.uploadedBatches
        XCTAssertEqual(batches.count, 1)
        let lastSync = await host.lastSyncTime
        XCTAssertNil(lastSync)
    }

    func testPartialUploadFailureKeepsTheEntryPendingUntilARetrySucceeds() async throws {
        let entry = SyncWireFixture.entry()
        let transport = FakeHistoryTransport(pages: [], uploads: [failedUpload(entry.id)])
        let store = FakeHistoryStore(entries: [entry])
        let host = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil))

        await host.sync(store: store)
        let pending = await host.pendingUploadCount
        XCTAssertEqual(pending, 1)
        let failure = await host.errorDescription
        XCTAssertEqual(failure, String(describing: SyncError.partialUploadFailure(1)))

        await host.sync(store: store)
        let remaining = await host.pendingUploadCount
        XCTAssertEqual(remaining, 0)
        let lastSync = await host.lastSyncTime
        XCTAssertEqual(lastSync, Date(timeIntervalSince1970: 42))
    }

    func testUnavailableCloudAndAMissingStoreFailBeforeTheTransport() async throws {
        let transport = FakeHistoryTransport(pages: [])
        let offline = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil), cloudAvailable: false)
        await offline.sync(store: FakeHistoryStore(entries: []))
        let offlineError = await offline.errorDescription
        XCTAssertEqual(offlineError, String(describing: SyncError.cloudUnavailable))

        let storeless = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil))
        await storeless.sync(store: nil)
        let storelessError = await storeless.errorDescription
        XCTAssertEqual(storelessError, String(describing: SyncError.delegateUnavailable))
        let fetches = await transport.requestedTokens.count
        XCTAssertEqual(fetches, 0)
    }

    func testStatusAssignmentsFollowTheAppleEnginesPublishOrder() async throws {
        let recorder = StatusRecorder()
        let host = HistoryHost(
            transport: FakeHistoryTransport(pages: []),
            tokens: OrderedCursorStore(token: nil),
            observer: recorder
        )

        await host.sync(store: FakeHistoryStore(entries: []))

        let fields = await recorder.fields
        XCTAssertEqual(fields, [
            .pendingUploadCount, .pendingDownloadCount, .isSyncing, .error,
            .pendingDownloadCount, .pendingDownloadCount, .pendingUploadCount,
            .pendingDownloadCount, .pendingUploadCount, .lastSyncTime, .isSyncing
        ])
    }

    func testSingleUploadAndDeleteReportFailuresAsTheEngineAlwaysHas() async throws {
        let entry = SyncWireFixture.entry()
        let transport = FakeHistoryTransport(pages: [], uploads: [failedUpload(entry.id)])
        await transport.failDeletes(with: CloudKitWebTestError.injected)
        let host = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil))
        let store = FakeHistoryStore(entries: [entry])

        do {
            try await host.upload(entry, store: store)
            XCTFail("Expected the upload failure")
        } catch SyncError.cloudKit {
            // Expected.
        }
        do {
            try await host.upload(entry, store: nil)
            XCTFail("Without a store the acknowledgement could not be kept")
        } catch SyncError.delegateUnavailable {
            // Expected.
        }
        do {
            try await host.delete(entry.id)
            XCTFail("Expected the delete failure")
        } catch SyncError.cloudKit {
            // Expected.
        }
        let batches = await transport.uploadedBatches
        XCTAssertEqual(batches, [[entry.id]])
    }

    private func page(_ changes: [HistoryRemoteChange], token: String, moreComing: Bool) -> HistoryChangePage {
        HistoryChangePage(changes: changes, serverChangeTokenData: Data(token.utf8), moreComing: moreComing)
    }

    private func failedUpload(_ id: UUID) -> HistoryUploadResult {
        HistoryUploadResult(acknowledgedIDs: [], remoteEntries: [], failures: [id: CloudKitWebTestError.injected])
    }
}
