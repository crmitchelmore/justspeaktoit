import Foundation
import SpeakCore
import XCTest

@testable import SpeakSync

final class ComparisonCoordinatorTests: XCTestCase {
    func testAnExpiredCursorIsClearedAndTheFeedReplayedOnce() async throws {
        let revision = ModelComparisonRevision(round: SyncWireFixture.round())
        let transport = FakeComparisonTransport(results: [
            .failure(ExpiredCursor()),
            .success(page(revision, token: "t1"))
        ])
        let cursor = MemoryCursorStore(token: Data("expired".utf8))
        let store = FakeComparisonStore()
        let host = ComparisonHost(transport: transport, tokens: cursor)

        await host.sync(store: store)

        let tokens = await transport.requestedTokens
        XCTAssertEqual(tokens, [Data("expired".utf8), nil])
        let saved = try await cursor.loadChangeToken()
        XCTAssertEqual(saved, Data("t1".utf8))
        let applied = await store.applied
        XCTAssertEqual(applied, [revision])
        let error = await host.lastErrorDescription
        XCTAssertNil(error)
    }

    func testASecondExpiryIsReportedRatherThanLooping() async throws {
        let transport = FakeComparisonTransport(results: [.failure(ExpiredCursor()), .failure(ExpiredCursor())])
        let host = ComparisonHost(transport: transport, tokens: MemoryCursorStore(token: Data("expired".utf8)))

        await host.sync(store: FakeComparisonStore())

        let tokens = await transport.requestedTokens
        XCTAssertEqual(tokens, [Data("expired".utf8), nil])
        let error = await host.lastErrorDescription
        XCTAssertEqual(error, String(describing: ExpiredCursor()))
    }

    func testAStoreFailureLeavesTheCursorForReplay() async throws {
        let revision = ModelComparisonRevision(round: SyncWireFixture.round())
        let cursor = MemoryCursorStore(token: nil)
        let store = FakeComparisonStore()
        await store.failApplies()
        let transport = FakeComparisonTransport(results: [.success(page(revision, token: "t1"))])
        let host = ComparisonHost(transport: transport, tokens: cursor)

        await host.sync(store: store)

        let saved = try await cursor.loadChangeToken()
        XCTAssertNil(saved)
        let error = await host.lastErrorDescription
        XCTAssertNotNil(error)
    }

    func testUnavailableCloudOrNoStoreTouchNothing() async throws {
        let transport = FakeComparisonTransport(results: [])
        let offline = ComparisonHost(transport: transport, tokens: MemoryCursorStore(token: nil), available: false)
        await offline.sync(store: FakeComparisonStore())
        let offlineError = await offline.lastErrorDescription
        XCTAssertEqual(offlineError, String(describing: SyncError.cloudUnavailable))

        let storeless = ComparisonHost(transport: transport, tokens: MemoryCursorStore(token: nil))
        await storeless.sync(store: nil)
        let storelessError = await storeless.lastErrorDescription
        XCTAssertNil(storelessError)
        let fetches = await transport.requestedTokens.count
        XCTAssertEqual(fetches, 0)
    }

    func testPendingRevisionsUploadAndNewerRemoteCopiesApplyFirst() async throws {
        let local = ModelComparisonRevision(round: SyncWireFixture.round())
        let remote = ModelComparisonRevision(deleting: UUID(), at: Date(timeIntervalSince1970: 5))
        let uploadResult = ComparisonUploadResult(acknowledged: [local], remote: [remote])
        let transport = FakeComparisonTransport(results: [], upload: uploadResult)
        let store = FakeComparisonStore(pending: [local])
        let host = ComparisonHost(transport: transport, tokens: MemoryCursorStore(token: nil))

        await host.sync(store: store)

        let applied = await store.applied
        XCTAssertEqual(applied, [remote])
        let acknowledged = await store.acknowledged
        XCTAssertEqual(acknowledged, [local])
        let lastSync = await host.lastSyncTime
        XCTAssertEqual(lastSync, Date(timeIntervalSince1970: 7))
    }

    private func page(_ revision: ModelComparisonRevision, token: String) -> ComparisonChangePage {
        ComparisonChangePage(changes: [.revision(revision)], serverChangeTokenData: Data(token.utf8), moreComing: false)
    }
}

private struct ExpiredCursor: Error {}

private actor ComparisonHost {
    let coordinator: ComparisonSyncCoordinator

    init(transport: any ComparisonSyncTransport, tokens: any SyncChangeTokenStore, available: Bool = true) {
        coordinator = ComparisonSyncCoordinator(
            transport: transport,
            tokenStore: tokens,
            cloudAvailability: { available },
            isChangeTokenExpired: { $0 is ExpiredCursor },
            now: { Date(timeIntervalSince1970: 7) }
        )
    }

    func sync(store: (any ComparisonSyncStore)?) async {
        await coordinator.sync(store: store)
    }

    var lastErrorDescription: String? { coordinator.status.lastError.map { String(describing: $0) } }
    var lastSyncTime: Date? { coordinator.status.lastSyncTime }
}

private actor FakeComparisonTransport: ComparisonSyncTransport {
    private var results: [Result<ComparisonChangePage, Error>]
    private let uploadResult: ComparisonUploadResult?
    private(set) var requestedTokens: [Data?] = []

    init(results: [Result<ComparisonChangePage, Error>], upload: ComparisonUploadResult? = nil) {
        self.results = results
        uploadResult = upload
    }

    func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage {
        requestedTokens.append(tokenData)
        return try (results.isEmpty ? .success(.empty) : results.removeFirst()).get()
    }

    func upload(revisions: [ModelComparisonRevision]) async -> ComparisonUploadResult {
        uploadResult ?? ComparisonUploadResult(acknowledged: revisions)
    }
}

private actor FakeComparisonStore: ComparisonSyncStore {
    private var pending: [ModelComparisonRevision]
    private(set) var applied: [ModelComparisonRevision] = []
    private(set) var acknowledged: [ModelComparisonRevision] = []
    private var failsApplies = false

    init(pending: [ModelComparisonRevision] = []) {
        self.pending = pending
    }

    func failApplies() {
        failsApplies = true
    }

    func pendingRevisions() async -> [ModelComparisonRevision] { pending }

    func applyRemoteRevision(_ revision: ModelComparisonRevision) async throws {
        if failsApplies { throw CloudKitWebTestError.injected }
        applied.append(revision)
    }

    func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) async throws {
        acknowledged += revisions
        pending.removeAll { revisions.contains($0) }
    }

    func applyLegacyDeletion(id: UUID) async throws {}
}
