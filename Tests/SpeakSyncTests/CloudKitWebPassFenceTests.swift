import Foundation
import XCTest

@testable import SpeakSync

/// A reconciliation pass bound to the web session its account was validated
/// in: it never continues into another session, and applies nothing that
/// arrives after it was cancelled.
final class CloudKitWebPassFenceTests: XCTestCase {
    private let consent = CloudKitWebSyncConsent(enabledFeatures: [.history])

    func testAPassRequestsNoFurtherPageOnceItsSessionEnds() async throws {
        let transport = ScriptedCloudKitTransport()
        let first = SyncWireFixture.entry(raw: "account A, page one")
        await transport.enqueue(SyncWireFixture.zoneChanges(
            [try SyncWireFixture.historyJSON(first)], syncToken: "cursor-a1", moreComing: true
        ))
        await transport.enqueue(SyncWireFixture.zoneChanges([], syncToken: "cursor-a2", moreComing: false))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let observer = HeldStatusObserver { status, field in
            field == .pendingDownloadCount && status.pendingDownloadCount == 1
        }
        let store = FakeHistoryStore(entries: [])
        let cursor = OrderedCursorStore(token: nil, loggingInto: store)
        let host = try await boundHost(client, cursor: cursor, observer: observer)

        let pass = Task { await host.sync(store: store) }
        try await eventually { await observer.isHolding }
        try await client.signOut()
        try await client.storeWebAuthToken("synthetic-account-b")
        await observer.release()
        await pass.value

        let tokens = await transport.requests.map(\.webAuthToken)
        XCTAssertEqual(tokens, ["synthetic-account-a"], "account A's next page must not be requested as B")
        let received = await store.received
        XCTAssertTrue(received.isEmpty, "account A's first page must not be applied after the sign-in")
        let saves = await cursor.saves
        XCTAssertTrue(saves.isEmpty)
        let error = await host.errorDescription
        XCTAssertEqual(error, String(describing: CloudKitWebServicesError.sessionChanged))
    }

    func testAPassSendsNoFurtherBatchOnceItsSessionEnds() async throws {
        let entries = (0...SyncSchema.batchSize).map { _ in SyncWireFixture.entry() }
        let sorted = entries.sorted { $0.id.uuidString < $1.id.uuidString }
        let firstBatch = Array(sorted.prefix(SyncSchema.batchSize))
        let lastEntry = try XCTUnwrap(sorted.last)
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(SyncWireFixture.zoneChanges([], syncToken: "cursor", moreComing: false))
        await transport.enqueue(CloudKitWebFixture.records(firstBatch.map {
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: $0.id.uuidString)
        }))
        await transport.enqueue(CloudKitWebFixture.records(firstBatch.map { ["recordName": $0.id.uuidString] }))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let observer = HeldStatusObserver { status, field in
            field == .pendingUploadCount && status.pendingUploadCount == 1
        }
        let store = FakeHistoryStore(entries: entries)
        let host = try await boundHost(client, cursor: MemoryCursorStore(token: nil), observer: observer)

        let pass = Task { await host.sync(store: store) }
        try await eventually { await observer.isHolding }
        try await client.signOut()
        try await client.storeWebAuthToken("synthetic-account-b")
        await observer.release()
        await pass.value

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.webAuthToken), [String?](repeating: "synthetic-account-a", count: 3))
        XCTAssertFalse(
            requests.contains { $0.bodyText.contains(lastEntry.id.uuidString) },
            "an entry still pending for account A was sent after the sign-in"
        )
        let acknowledged = await store.acknowledgedIDs
        XCTAssertEqual(acknowledged, Set(firstBatch.map(\.id)), "what CloudKit confirmed before the sign-in stays")
        let error = await host.errorDescription
        XCTAssertEqual(error, String(describing: CloudKitWebServicesError.sessionChanged))
    }

    func testACancelledPassAppliesNoPageThatArrivesLate() async throws {
        let transport = ScriptedCloudKitTransport()
        let late = SyncWireFixture.entry(raw: "arrived after cancellation")
        await transport.enqueue(SyncWireFixture.zoneChanges(
            [try SyncWireFixture.historyJSON(late)], syncToken: "late", moreComing: false
        ))
        await transport.holdRequestsIgnoringCancellation()
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let store = FakeHistoryStore(entries: [])
        let cursor = OrderedCursorStore(token: nil, loggingInto: store)
        let host = try await boundHost(client, cursor: cursor)

        let pass = Task { await host.sync(store: store) }
        try await eventually { await transport.heldCount == 1 }
        pass.cancel()
        await transport.releaseHeldRequests()
        await pass.value

        let received = await store.received
        XCTAssertTrue(received.isEmpty, "a cancelled pass applied a page its transport returned regardless")
        let saves = await cursor.saves
        XCTAssertTrue(saves.isEmpty, "a cancelled pass advanced its cursor")
        let error = await host.errorDescription
        XCTAssertEqual(error, String(describing: CancellationError()))
    }

    func testACancelledPassRecordsNoAcknowledgementThatArrivesLate() async throws {
        let entry = SyncWireFixture.entry(raw: "uploaded as the pass was cancelled")
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(SyncWireFixture.zoneChanges([], syncToken: "cursor", moreComing: false))
        await transport.enqueue(CloudKitWebFixture.records([
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: entry.id.uuidString)
        ]))
        await transport.enqueue(CloudKitWebFixture.records([["recordName": entry.id.uuidString]]))
        await transport.holdRequestsIgnoringCancellation(pathSuffix: "records/modify")
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let store = FakeHistoryStore(entries: [entry])
        let host = try await boundHost(client, cursor: MemoryCursorStore(token: nil))

        let pass = Task { await host.sync(store: store) }
        try await eventually { await transport.heldCount == 1 }
        pass.cancel()
        await transport.releaseHeldRequests()
        await pass.value

        let acknowledged = await store.acknowledgedIDs
        XCTAssertTrue(acknowledged.isEmpty, "a cancelled pass recorded an acknowledgement that arrived late")
        let pending = await host.pendingUploadCount
        XCTAssertEqual(pending, 1, "the entry stays pending and the next pass resolves it by record ID")
    }

    /// The shared coordinator bound to the session current now, as a desktop
    /// host binds each pass to the session it validated.
    private func boundHost(
        _ client: CloudKitWebServicesClient,
        cursor: any SyncChangeTokenStore,
        observer: (any HistorySyncStatusObserver)? = nil
    ) async throws -> HistoryHost {
        let session = await client.session()
        return HistoryHost(
            transport: try CloudKitWebHistorySyncTransport(client: client, consent: consent, session: session),
            tokens: cursor,
            observer: observer,
            fence: CloudKitWebSessionFence(client: client, session: session)
        )
    }
}
