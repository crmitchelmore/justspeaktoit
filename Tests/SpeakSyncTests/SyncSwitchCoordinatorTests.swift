import Foundation
import XCTest
@testable import SpeakSync

final class SyncSwitchCoordinatorTests: XCTestCase {
    func testDisableDuringFetchPreventsApplyUploadAndQueuedPassThenEnableCatchesUp() async throws {
        let local = SyncWireFixture.entry(raw: "kept local")
        let remote = SyncWireFixture.entry(raw: "arrived after off")
        let store = FakeHistoryStore(entries: [local])
        let cursor = OrderedCursorStore(token: nil)
        let transport = FakeHistoryTransport(pages: [HistoryChangePage(
            changes: [.changed(remote)], serverChangeTokenData: Data("unaccepted".utf8), moreComing: true
        )])
        let host = HistoryHost(transport: transport, tokens: cursor)
        await transport.setOnFetch {
            await host.sync(store: store) // queues a follow-up on the actual suspended pass
            await host.setSyncEnabled(false)
        }
        await host.sync(store: store)
        let fetched = await transport.requestedTokens.count
        let uploaded = await transport.uploadedBatches
        let received = await store.received
        let saved = await cursor.saves
        let error = await host.errorDescription
        let downloads = await host.pendingDownloadCount
        XCTAssertEqual(fetched, 1)
        XCTAssertEqual(downloads, 0)
        XCTAssertTrue(uploaded.isEmpty)
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertNil(error, "Off is a choice, not a failed sync")

        await host.setSyncEnabled(true)
        await host.sync(store: store)
        let caughtUp = await transport.uploadedBatches
        let pending = await store.pendingEntries()
        XCTAssertEqual(caughtUp, [[local.id]])
        XCTAssertTrue(pending.isEmpty)
    }

    func testInitiallyDisabledSyncUploadAndDeleteNeverTouchTransport() async throws {
        let entry = SyncWireFixture.entry()
        let transport = FakeHistoryTransport(pages: [])
        let store = FakeHistoryStore(entries: [entry])
        let host = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil))
        await host.setSyncEnabled(false)
        await host.sync(store: store)
        do {
            try await host.upload(entry, store: store); XCTFail("Expected disabled upload")
        } catch is HistorySyncDisabledError {} catch { XCTFail("Unexpected \(error)") }
        do {
            try await host.delete(entry.id); XCTFail("Expected disabled delete")
        } catch is HistorySyncDisabledError {} catch { XCTFail("Unexpected \(error)") }
        let fetched = await transport.requestedTokens
        let uploaded = await transport.uploadedBatches
        let deleted = await transport.deleted
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertTrue(uploaded.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
    }
}
