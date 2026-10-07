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
        try await observer.waitUntilHolding()
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
        try await assertNoFurtherBatchOnceTheSessionEnds(reachingTheBoundaryLate: false)
    }

    /// The pass reaches its batch boundary only after a whole batch — three
    /// requests, with a hundred records encoded and decoded — which a loaded
    /// runner can take longer over than the 5,000 scheduler turns `eventually`
    /// waits: this scenario failed on Linux CI while the pass was still on its
    /// way. Holding the pass's requests for those turns stands in for that
    /// runner; the observer meets the pass whenever it arrives.
    func testAPassThatReachesItsBatchBoundaryLateIsStillStoppedThere() async throws {
        try await assertNoFurtherBatchOnceTheSessionEnds(reachingTheBoundaryLate: true)
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

    /// Holds the pass once its first full batch is acknowledged and signs
    /// another account in: the pass sends nothing more, and keeps what CloudKit
    /// confirmed before the sign-in. Reaching the boundary late, the pass's
    /// requests are held until a wait counted in scheduler turns gives up.
    private func assertNoFurtherBatchOnceTheSessionEnds(
        reachingTheBoundaryLate late: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
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

        if late {
            await transport.holdRequests()
        }
        let pass = Task { await host.sync(store: store) }
        if late {
            // The shared `eventually` gives up after 5,000 turns: here, on a
            // pass that is still on its way.
            let heldInTime = await Self.isHeld(observer, withinTurns: 5_000)
            XCTAssertFalse(
                heldInTime, "the batch boundary was reached with every request held", file: file, line: line
            )
            await transport.releaseHeldRequests()
        }
        try await observer.waitUntilHolding()
        try await client.signOut()
        try await client.storeWebAuthToken("synthetic-account-b")
        await observer.release()
        await pass.value

        let requests = await transport.requests
        let tokens = requests.map(\.webAuthToken)
        XCTAssertEqual(tokens, [String?](repeating: "synthetic-account-a", count: 3), file: file, line: line)
        XCTAssertFalse(
            requests.contains { $0.bodyText.contains(lastEntry.id.uuidString) },
            "an entry still pending for account A was sent after the sign-in", file: file, line: line
        )
        let acknowledged = await store.acknowledgedIDs
        XCTAssertEqual(
            acknowledged, Set(firstBatch.map(\.id)), "what CloudKit confirmed before the sign-in stays",
            file: file, line: line
        )
        let error = await host.errorDescription
        XCTAssertEqual(error, String(describing: CloudKitWebServicesError.sessionChanged), file: file, line: line)
    }

    /// The wait these tests used to make: look for the hold between scheduler
    /// turns, and give up after `turns` of them however far the pass has got.
    private static func isHeld(_ observer: HeldStatusObserver, withinTurns turns: Int) async -> Bool {
        for _ in 0..<turns {
            if await observer.isHolding { return true }
            await Task.yield()
        }
        return false
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
