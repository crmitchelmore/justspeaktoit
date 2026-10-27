import Foundation
import SpeakCore
import XCTest

@testable import SpeakSync

@MainActor
final class HistorySyncTerminalStatusTests: XCTestCase {
    func testQueuedSuccessfulPassBeginsCleanAndFinishesWithoutTheRecoveredFailure() async throws {
        let fixture = await makeFixture(holdAtCompletion: false)
        let done = start(fixture)
        try await completed(fixture.arrived)

        let errorWhileHeld = await fixture.host.errorDescription
        let pendingWhileHeld = await fixture.host.pendingUploadCount
        let batchesWhileHeld = await fixture.transport.uploadedBatches
        let fetchesWhileHeld = await fixture.transport.requestedTokens.count
        let syncingWhileHeld = await fixture.host.isSyncing
        XCTAssertNil(errorWhileHeld, "A queued pass begins with the same clean status as a fresh sync")
        XCTAssertEqual(pendingWhileHeld, 1)
        XCTAssertEqual(batchesWhileHeld, [[fixture.entry.id]])
        XCTAssertEqual(fetchesWhileHeld, 2, "The real second fetch, not scheduler turns, owns this hold")
        XCTAssertTrue(syncingWhileHeld, "Clearing the previous error does not claim terminal success")

        await fixture.pause.release()
        try await completed(done)
        let error = await fixture.host.errorDescription
        let pending = await fixture.host.pendingUploadCount
        let acknowledged = await fixture.store.acknowledgedIDs
        let batches = await fixture.transport.uploadedBatches
        let syncing = await fixture.host.isSyncing
        XCTAssertNil(error)
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(acknowledged, [fixture.entry.id])
        XCTAssertEqual(batches, [[fixture.entry.id], [fixture.entry.id]])
        XCTAssertFalse(syncing)
    }

    func testQueuedFailedPassKeepsItsFailureAndUnacknowledgedEntry() async throws {
        let fixture = await makeFixture(holdAtCompletion: false, followUpFails: true)
        let done = start(fixture)
        try await completed(fixture.arrived)
        await fixture.pause.release()
        try await completed(done)

        let error = await fixture.host.errorDescription
        let pending = await fixture.host.pendingUploadCount
        let acknowledged = await fixture.store.acknowledgedIDs
        let lastSync = await fixture.host.lastSyncTime
        let batches = await fixture.transport.uploadedBatches
        XCTAssertEqual(error, String(describing: SyncError.partialUploadFailure(1)))
        XCTAssertEqual(pending, 1)
        XCTAssertTrue(acknowledged.isEmpty)
        XCTAssertNil(lastSync)
        XCTAssertEqual(batches, [[fixture.entry.id], [fixture.entry.id]])
    }

    func testQueuedSuccessDoesNotClearNewerDirectUploadFailureDuringStatusPublication() async throws {
        let direct = SyncWireFixture.entry(raw: "separate direct upload")
        let fixture = await makeFixture(holdAtCompletion: true, directFailure: direct)
        let done = start(fixture)
        try await completed(fixture.arrived)
        let pending = await fixture.host.pendingUploadCount
        XCTAssertEqual(pending, 0, "The queued reconciliation has genuinely acknowledged its row")

        do {
            try await fixture.host.upload(direct, store: FakeHistoryStore(entries: [direct]))
            XCTFail("The separately admitted direct upload must fail")
        } catch SyncError.cloudKit {
            // This is a newer error than the queued pass's recovered failure.
        }
        let newerError = await fixture.host.errorDescription
        XCTAssertNotNil(newerError)
        XCTAssertNotEqual(newerError, String(describing: SyncError.partialUploadFailure(1)))
        await fixture.pause.release()
        try await completed(done)

        let retainedError = await fixture.host.errorDescription
        XCTAssertEqual(retainedError, newerError)
        let batches = await fixture.transport.uploadedBatches
        XCTAssertEqual(batches, [[fixture.entry.id], [fixture.entry.id], [direct.id]])
    }

    func testQueuedSuccessDoesNotClearNewerCloudFailureDuringStatusPublication() async throws {
        let fixture = await makeFixture(holdAtCompletion: true)
        let done = start(fixture)
        try await completed(fixture.arrived)
        await fixture.host.reportUnavailableCloud()
        await fixture.pause.release()
        try await completed(done)

        let error = await fixture.host.errorDescription
        let available = await fixture.host.cloudAvailable
        let pending = await fixture.host.pendingUploadCount
        XCTAssertEqual(error, String(describing: SyncError.cloudUnavailable))
        XCTAssertFalse(available)
        XCTAssertEqual(pending, 0)
    }

    private struct Fixture {
        let entry: SyncableHistoryEntry
        let transport: FakeHistoryTransport
        let store: FakeHistoryStore
        let host: HistoryHost
        let arrived: XCTestExpectation
        let pause: TerminalStatusPause
    }

    private func makeFixture(
        holdAtCompletion: Bool,
        followUpFails: Bool = false,
        directFailure: SyncableHistoryEntry? = nil
    ) async -> Fixture {
        let entry = SyncWireFixture.entry()
        var uploads = [failedUpload(entry.id)]
        uploads.append(followUpFails ? failedUpload(entry.id) : .success(ids: [entry.id]))
        if let directFailure { uploads.append(failedUpload(directFailure.id)) }
        let transport = FakeHistoryTransport(pages: [], uploads: uploads)
        let store = FakeHistoryStore(entries: [entry])
        let arrived = XCTestExpectation(description: "Queued pass reached its owned status boundary")
        let pause = TerminalStatusPause(arrived: arrived) { _, field in
            holdAtCompletion && field == .lastSyncTime
        }
        let host = HistoryHost(transport: transport, tokens: OrderedCursorStore(token: nil), observer: pause)
        // The actual running coordinator admits this trigger as a follow-up.
        await transport.setOnFetch {
            await host.sync(store: store)
            if !holdAtCompletion {
                await transport.setOnFetch { await pause.hold() }
            }
        }
        return Fixture(entry: entry, transport: transport, store: store, host: host, arrived: arrived, pause: pause)
    }

    private func start(_ fixture: Fixture) -> XCTestExpectation {
        let done = XCTestExpectation(description: "Both reconciliation passes returned")
        let exited = XCTestExpectation(description: "Owned sync task exited")
        let task = Task {
            defer { exited.fulfill() }
            await fixture.host.sync(store: fixture.store)
            done.fulfill()
        }
        addTeardownBlock {
            task.cancel()
            await fixture.pause.release()
            let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(result, .completed, "Owned sync task must exit after releasing its status boundary")
        }
        return done
    }

    private func completed(
        _ expectation: XCTestExpectation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        guard result == .completed else {
            XCTFail("Owned coordinator boundary did not arrive", file: file, line: line)
            throw TerminalStatusTimeout()
        }
    }

    private func failedUpload(_ id: UUID) -> HistoryUploadResult {
        HistoryUploadResult(acknowledgedIDs: [], remoteEntries: [], failures: [id: CloudKitWebTestError.injected])
    }
}

private struct TerminalStatusTimeout: Error {}

/// Release-before-arrival also opens the gate, so assertion failures cannot
/// strand a later status callback after teardown has already begun.
private actor TerminalStatusPause: HistorySyncStatusObserver {
    private let arrived: XCTestExpectation
    private let predicate: @Sendable (HistorySyncStatus, HistorySyncStatus.Field) -> Bool
    private var hasHeld = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        arrived: XCTestExpectation,
        predicate: @escaping @Sendable (HistorySyncStatus, HistorySyncStatus.Field) -> Bool
    ) {
        self.arrived = arrived
        self.predicate = predicate
    }

    func historySync(_ status: HistorySyncStatus, didChange field: HistorySyncStatus.Field) async {
        guard predicate(status, field) else { return }
        await hold()
    }

    func hold() async {
        guard !released, !hasHeld else { return }
        hasHeld = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            arrived.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private extension HistoryHost {
    func reportUnavailableCloud() async {
        await coordinator.updateCloudAvailability(false, error: SyncError.cloudUnavailable)
    }

    var cloudAvailable: Bool { coordinator.status.isCloudAvailable }
}
