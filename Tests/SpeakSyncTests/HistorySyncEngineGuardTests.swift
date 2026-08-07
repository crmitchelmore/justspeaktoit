import Foundation
import XCTest

@testable import SpeakSync

/// Guard-rail and single-entry paths of HistorySyncEngine that the batch sync
/// tests do not cover: cloud-unavailable behavior, missing delegate, single
/// uploads and deletes, server-copy reconciliation, and stalled-acknowledgement
/// detection. All CloudKit access goes through the recorded fake transport.
@MainActor
final class HistorySyncEngineGuardTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HistorySyncEngineGuardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Cloud unavailable

    func testSyncWhenCloudUnavailable_setsErrorAndNeverTouchesTransport() async {
        let transport = RecordingTransport()
        let delegate = AckingDelegate(entries: [makeEntry(text: "queued")])
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: false, delegate: delegate
        )

        await engine.sync()

        guard case .some(SyncError.cloudUnavailable) = engine.state.error as? SyncError else {
            XCTFail("Expected cloudUnavailable, got \(String(describing: engine.state.error))")
            return
        }
        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(transport.uploadedBatches.count, 0)
        XCTAssertNil(engine.state.lastSyncTime)
        XCTAssertEqual(engine.state.pendingUploadCount, 1, "Entry must remain pending")
    }

    func testUploadWhenCloudUnavailable_throwsWithoutTouchingTransport() async {
        let transport = RecordingTransport()
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: false
        )

        do {
            try await engine.upload(entry: makeEntry(text: "queued"))
            XCTFail("Expected cloudUnavailable")
        } catch SyncError.cloudUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.uploadedBatches.count, 0)
    }

    func testDeleteWhenCloudUnavailable_throwsWithoutTouchingTransport() async {
        let transport = RecordingTransport()
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: false
        )

        do {
            try await engine.delete(entryID: UUID())
            XCTFail("Expected cloudUnavailable")
        } catch SyncError.cloudUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.deletedIDs, [])
    }

    // MARK: - Missing delegate

    func testSyncWithoutDelegate_failsWithDelegateUnavailable() async {
        let transport = RecordingTransport()
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: nil
        )

        await engine.sync()

        guard case .some(SyncError.delegateUnavailable) = engine.state.error as? SyncError else {
            XCTFail("Expected delegateUnavailable, got \(String(describing: engine.state.error))")
            return
        }
        XCTAssertEqual(transport.fetchCount, 0)
    }

    // MARK: - Single-entry upload

    func testSingleUploadSuccess_acknowledgesEntryAndClearsError() async throws {
        let entry = makeEntry(text: "hello")
        let transport = RecordingTransport()
        let delegate = AckingDelegate(entries: [entry])
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: delegate
        )

        try await engine.upload(entry: entry)

        XCTAssertEqual(transport.uploadedBatches, [[entry.id]])
        XCTAssertEqual(delegate.acknowledgedIDs, [entry.id])
        XCTAssertNil(engine.state.error)
        XCTAssertEqual(engine.state.pendingUploadCount, 0)
    }

    func testSingleUploadFailure_throwsCloudKitErrorAndKeepsEntryPending() async {
        let entry = makeEntry(text: "doomed")
        let transport = RecordingTransport()
        transport.uploadFailures = [entry.id: TestFailure()]
        let delegate = AckingDelegate(entries: [entry])
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: delegate
        )

        do {
            try await engine.upload(entry: entry)
            XCTFail("Expected cloudKit error")
        } catch SyncError.cloudKit {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNotNil(engine.state.error)
        XCTAssertEqual(delegate.acknowledgedIDs, [])
        XCTAssertEqual(engine.state.pendingUploadCount, 1)
    }

    func testUploadReturningServerCopy_forwardsRemoteEntryToDelegate() async throws {
        // CloudKit resolved a conflict by returning its own (newer) record:
        // the engine must hand that copy to the delegate before acknowledging.
        let localEntry = makeEntry(text: "local-version", updatedAt: Date(timeIntervalSince1970: 10))
        let serverCopy = makeEntry(
            id: localEntry.id, text: "server-version", updatedAt: Date(timeIntervalSince1970: 20)
        )
        let transport = RecordingTransport()
        transport.remoteEntriesByID = [localEntry.id: serverCopy]
        let delegate = AckingDelegate(entries: [localEntry])
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: delegate
        )

        try await engine.upload(entry: localEntry)

        XCTAssertEqual(delegate.receivedEntries.map(\.rawTranscription), ["server-version"])
        XCTAssertEqual(delegate.acknowledgedIDs, [localEntry.id])
    }

    // MARK: - Delete

    func testDeleteSuccess_forwardsToTransport() async throws {
        let transport = RecordingTransport()
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true
        )
        let id = UUID()

        try await engine.delete(entryID: id)

        XCTAssertEqual(transport.deletedIDs, [id])
    }

    func testDeleteFailure_isWrappedAsCloudKitError() async {
        let transport = RecordingTransport()
        transport.deleteError = TestFailure()
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true
        )

        do {
            try await engine.delete(entryID: UUID())
            XCTFail("Expected cloudKit error")
        } catch SyncError.cloudKit {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Stalled acknowledgement

    func testDelegateThatNeverAcknowledges_failsInsteadOfLoopingForever() async {
        let entry = makeEntry(text: "stuck")
        let transport = RecordingTransport()
        let delegate = NeverAckingDelegate(entries: [entry])
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: delegate
        )

        await engine.sync()

        guard case .some(SyncError.reconciliationIncomplete(1)) = engine.state.error as? SyncError
        else {
            XCTFail("Expected reconciliationIncomplete(1), got \(String(describing: engine.state.error))")
            return
        }
        XCTAssertNil(engine.state.lastSyncTime)
        XCTAssertEqual(
            transport.uploadedBatches.count, 1,
            "Engine must stop after detecting the stalled batch, not retry forever"
        )
    }

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        text: String,
        updatedAt: Date = Date(timeIntervalSince1970: 10)
    ) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscription: text,
            postProcessedText: nil,
            model: "test",
            duration: 1,
            wordCount: 1,
            originPlatform: "mac",
            updatedAt: updatedAt
        )
    }
}

// MARK: - Fakes

@MainActor
private final class RecordingTransport: HistorySyncTransport {
    private(set) var fetchCount = 0
    private(set) var uploadedBatches: [[UUID]] = []
    private(set) var deletedIDs: [UUID] = []
    var uploadFailures: [UUID: Error] = [:]
    var remoteEntriesByID: [UUID: SyncableHistoryEntry] = [:]
    var deleteError: Error?

    func fetchChanges(after _: Data?) async throws -> HistoryChangePage {
        fetchCount += 1
        return HistoryChangePage(changes: [], serverChangeTokenData: nil, moreComing: false)
    }

    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        uploadedBatches.append(entries.map(\.id))
        let failed = Set(uploadFailures.keys)
        let acknowledged = Set(entries.map(\.id)).subtracting(failed)
        return HistoryUploadResult(
            acknowledgedIDs: acknowledged,
            remoteEntries: entries.compactMap { remoteEntriesByID[$0.id] },
            failures: uploadFailures.filter { failure in entries.contains { $0.id == failure.key } }
        )
    }

    func delete(entryID: UUID) async throws {
        if let deleteError {
            throw deleteError
        }
        deletedIDs.append(entryID)
    }
}

@MainActor
private final class AckingDelegate: HistorySyncDelegate {
    private var entriesByID: [UUID: SyncableHistoryEntry]
    private(set) var acknowledgedIDs: Set<UUID> = []
    private(set) var receivedEntries: [SyncableHistoryEntry] = []

    init(entries: [SyncableHistoryEntry]) {
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    func pendingEntries() -> [SyncableHistoryEntry] {
        entriesByID.values.filter { !acknowledgedIDs.contains($0.id) }
    }

    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        receivedEntries.append(entry)
        entriesByID[entry.id] = entry
    }

    func didDeleteRemoteEntry(id: UUID) async {
        entriesByID.removeValue(forKey: id)
        acknowledgedIDs.remove(id)
    }

    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        acknowledgedIDs.formUnion(ids)
    }
}

/// Simulates a delegate whose persistence layer silently drops acknowledgements.
@MainActor
private final class NeverAckingDelegate: HistorySyncDelegate {
    private let entries: [SyncableHistoryEntry]

    init(entries: [SyncableHistoryEntry]) {
        self.entries = entries
    }

    func pendingEntries() -> [SyncableHistoryEntry] { entries }
    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {}
    func didDeleteRemoteEntry(id: UUID) async {}
    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {}
}

private struct TestFailure: LocalizedError {
    var errorDescription: String? { "test failure" }
}
