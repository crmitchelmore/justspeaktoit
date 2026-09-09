import Foundation
import XCTest

@testable import SpeakSync

@MainActor
final class HistorySyncEngineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HistorySyncEngineTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testFullBatchSuccessAcknowledgesEveryEntryAndResetsPendingCounts() async {
        let entries = [makeEntry(text: "one"), makeEntry(text: "two")]
        let transport = FakeHistorySyncTransport(
            pages: [.empty],
            uploads: [.success(ids: Set(entries.map(\.id)))]
        )
        let delegate = FakeHistorySyncDelegate(entries: entries)
        let engine = makeEngine(transport: transport, delegate: delegate)

        await engine.sync()

        XCTAssertEqual(delegate.acknowledgedIDs, Set(entries.map(\.id)))
        XCTAssertEqual(engine.state.pendingUploadCount, 0)
        XCTAssertEqual(engine.state.pendingDownloadCount, 0)
        XCTAssertNil(engine.state.error)
        XCTAssertNotNil(engine.state.lastSyncTime)
    }

    func testFailedUploadRemainsPendingUntilRetrySucceeds() async {
        let entry = makeEntry(text: "retry")
        let failure = TestFailure()
        let transport = FakeHistorySyncTransport(
            pages: [.empty, .empty],
            uploads: [
                HistoryUploadResult(acknowledgedIDs: [], remoteEntries: [], failures: [entry.id: failure]),
                .success(ids: [entry.id])
            ]
        )
        let delegate = FakeHistorySyncDelegate(entries: [entry])
        let engine = makeEngine(transport: transport, delegate: delegate)

        await engine.sync()
        XCTAssertEqual(engine.state.pendingUploadCount, 1)
        XCTAssertNotNil(engine.state.error)
        XCTAssertNil(engine.state.lastSyncTime)

        await engine.sync()
        XCTAssertEqual(engine.state.pendingUploadCount, 0)
        XCTAssertNil(engine.state.error)
        XCTAssertNotNil(engine.state.lastSyncTime)
    }

    func testPaginationCoalescesDuplicatesAndAppliesFinalTombstone() async {
        let deleted = makeEntry(text: "delete me")
        let duplicateID = UUID()
        let firstDuplicate = makeEntry(id: duplicateID, text: "old", updatedAt: Date(timeIntervalSince1970: 10))
        let finalDuplicate = makeEntry(id: duplicateID, text: "new", updatedAt: Date(timeIntervalSince1970: 20))
        let token1 = Data("page-1".utf8)
        let token2 = Data("page-2".utf8)
        let transport = FakeHistorySyncTransport(
            pages: [
                HistoryChangePage(
                    changes: [.changed(deleted), .changed(firstDuplicate)],
                    serverChangeTokenData: token1,
                    moreComing: true
                ),
                HistoryChangePage(
                    changes: [.deleted(deleted.id), .changed(finalDuplicate)],
                    serverChangeTokenData: token2,
                    moreComing: false
                )
            ],
            uploads: []
        )
        let delegate = FakeHistorySyncDelegate(entries: [deleted])
        let engine = makeEngine(transport: transport, delegate: delegate)

        await engine.sync()

        XCTAssertEqual(transport.requestedTokens, [nil, token1])
        XCTAssertEqual(defaults.data(forKey: SyncConfiguration.syncTokenKey), token2)
        XCTAssertEqual(delegate.deletedIDs, [deleted.id])
        XCTAssertFalse(delegate.receivedEntries.contains { $0.id == deleted.id })
        XCTAssertEqual(delegate.receivedEntries.filter { $0.id == duplicateID }.count, 1)
        XCTAssertEqual(delegate.receivedEntries.first { $0.id == duplicateID }?.rawTranscription, "new")
        XCTAssertEqual(engine.state.pendingDownloadCount, 0)
    }

    func testPaginationWithoutAdvancingTokenFailsTruthfully() async {
        let transport = FakeHistorySyncTransport(
            pages: [HistoryChangePage(changes: [], serverChangeTokenData: nil, moreComing: true)],
            uploads: []
        )
        let delegate = FakeHistorySyncDelegate(entries: [])
        let engine = makeEngine(transport: transport, delegate: delegate)

        await engine.sync()

        XCTAssertNotNil(engine.state.error)
        XCTAssertNil(engine.state.lastSyncTime)
        XCTAssertEqual(engine.state.pendingDownloadCount, 0)
    }

    func testPaginationWithRepeatedTokenFailsInsteadOfLooping() async {
        let repeatedToken = Data("same-page".utf8)
        defaults.set(repeatedToken, forKey: SyncConfiguration.syncTokenKey)
        let transport = FakeHistorySyncTransport(
            pages: [
                HistoryChangePage(
                    changes: [],
                    serverChangeTokenData: repeatedToken,
                    moreComing: true
                )
            ],
            uploads: []
        )
        let delegate = FakeHistorySyncDelegate(entries: [])
        let engine = makeEngine(transport: transport, delegate: delegate)

        await engine.sync()

        XCTAssertNotNil(engine.state.error)
        XCTAssertNil(engine.state.lastSyncTime)
        XCTAssertEqual(transport.requestedTokens, [repeatedToken])
    }

    /// A push arriving mid-pass may be about a record the running fetch has
    /// already gone past. Dropping it left the phone stale until some later,
    /// unrelated sync, so the trigger has to survive as a follow-up pass.
    func testATriggerDuringAnActivePassStillGetsItsOwnReconciliation() async {
        let transport = FakeHistorySyncTransport(pages: [.empty, .empty], uploads: [])
        let delegate = FakeHistorySyncDelegate(entries: [])
        let engine = makeEngine(transport: transport, delegate: delegate)
        transport.onFetch = { await engine.sync() }

        await engine.sync()

        XCTAssertEqual(
            transport.requestedTokens.count,
            2,
            "the trigger observed during the first pass must produce a second one"
        )
        XCTAssertNil(engine.state.error)
    }

    func testFailedDelegateDurabilityRetainsTokenUntilReplayCommits() async {
        let oldToken = Data("old".utf8)
        let nextToken = Data("next".utf8)
        defaults.set(oldToken, forKey: SyncConfiguration.syncTokenKey)
        let changed = makeEntry(text: "changed")
        let deleted = makeEntry(text: "deleted")
        let page = HistoryChangePage(changes: [.changed(changed), .deleted(deleted.id)],
                                     serverChangeTokenData: nextToken, moreComing: false)
        let transport = FakeHistorySyncTransport(pages: [page, page], uploads: [])
        let delegate = FakeHistorySyncDelegate(entries: [deleted])
        delegate.failDurability = true
        let engine = makeEngine(transport: transport, delegate: delegate)

        await engine.sync()
        XCTAssertNotNil(engine.state.error)
        XCTAssertEqual(defaults.data(forKey: SyncConfiguration.syncTokenKey), oldToken)
        delegate.failDurability = false
        await engine.sync()
        XCTAssertNil(engine.state.error)
        XCTAssertEqual(transport.requestedTokens, [oldToken, oldToken])
        XCTAssertEqual(defaults.data(forKey: SyncConfiguration.syncTokenKey), nextToken)
        XCTAssertEqual(delegate.acknowledgedIDs, [changed.id])
        XCTAssertTrue(delegate.pendingEntries().isEmpty)
    }

    private func makeEngine(
        transport: FakeHistorySyncTransport,
        delegate: FakeHistorySyncDelegate
    ) -> HistorySyncEngine {
        let engine = HistorySyncEngine(
            transport: transport,
            defaults: defaults,
            cloudAvailable: true,
            delegate: delegate
        )
        return engine
    }

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
            originPlatform: "ios",
            updatedAt: updatedAt
        )
    }
}

private extension HistoryChangePage {
    static var empty: HistoryChangePage {
        HistoryChangePage(changes: [], serverChangeTokenData: nil, moreComing: false)
    }
}

@MainActor
private final class FakeHistorySyncTransport: HistorySyncTransport {
    private var pages: [HistoryChangePage]
    private var uploads: [HistoryUploadResult]
    private(set) var requestedTokens: [Data?] = []
    /// Runs inside a fetch, so a test can model a trigger that arrives while a
    /// reconciliation pass is already under way.
    var onFetch: (() async -> Void)?

    init(pages: [HistoryChangePage], uploads: [HistoryUploadResult]) {
        self.pages = pages
        self.uploads = uploads
    }

    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        requestedTokens.append(tokenData)
        if let onFetch {
            self.onFetch = nil
            await onFetch()
        }
        return pages.isEmpty ? .empty : pages.removeFirst()
    }

    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        uploads.isEmpty ? .success(ids: Set(entries.map(\.id))) : uploads.removeFirst()
    }

    func delete(entryID _: UUID) async throws {}
}

@MainActor
private final class FakeHistorySyncDelegate: HistorySyncDurabilityDelegate {
    var failDurability = false

    func persistRemoteChanges() async throws {
        if failDurability { throw TestFailure() }
    }

    private var entriesByID: [UUID: SyncableHistoryEntry]
    private(set) var acknowledgedIDs: Set<UUID> = []
    private(set) var receivedEntries: [SyncableHistoryEntry] = []
    private(set) var deletedIDs: [UUID] = []

    init(entries: [SyncableHistoryEntry]) {
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    func pendingEntries() -> [SyncableHistoryEntry] {
        entriesByID.values.filter { !acknowledgedIDs.contains($0.id) }
    }

    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        receivedEntries.append(entry)
        if entry.updatedAt >= (entriesByID[entry.id]?.updatedAt ?? .distantPast) {
            entriesByID[entry.id] = entry
            acknowledgedIDs.insert(entry.id)
        }
    }

    func didDeleteRemoteEntry(id: UUID) async {
        deletedIDs.append(id)
        entriesByID.removeValue(forKey: id)
        acknowledgedIDs.remove(id)
    }

    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        acknowledgedIDs.formUnion(ids.intersection(Set(entriesByID.keys)))
    }
}

private struct TestFailure: LocalizedError {
    var errorDescription: String? { "test failure" }
}
