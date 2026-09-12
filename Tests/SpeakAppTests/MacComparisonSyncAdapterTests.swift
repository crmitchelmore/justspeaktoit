import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class MacComparisonSyncAdapterTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacComparisonSyncAdapterTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "MacComparisonSyncAdapterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testPendingRounds_excludeAcknowledgedIDsAndSurviveRelaunch() async {
        let store = ComparisonRoundStore(directory: directory)
        let adapter = MacComparisonSyncAdapter(store: store, defaults: defaults)
        let first = makeRound(offset: 0)
        let second = makeRound(offset: 1)
        store.upsert(first)
        store.upsert(second)
        XCTAssertEqual(Set(adapter.pendingRounds().map(\.id)), [first.id, second.id])

        await adapter.didAcknowledgeSyncedRounds(ids: [first.id])
        XCTAssertEqual(adapter.pendingRounds().map(\.id), [second.id])

        let relaunched = MacComparisonSyncAdapter(store: store, defaults: defaults)
        XCTAssertEqual(relaunched.pendingRounds().map(\.id), [second.id])
    }

    func testRemoteRound_isAppliedWithoutBecomingPending() async {
        let store = ComparisonRoundStore(directory: directory)
        let adapter = MacComparisonSyncAdapter(store: store, defaults: defaults)
        let remote = makeRound(offset: 0)

        await adapter.didReceiveRemoteRound(remote)

        XCTAssertEqual(store.rounds, [remote])
        XCTAssertTrue(adapter.pendingRounds().isEmpty)
    }

    func testNewerLocalRound_staysPendingWhenAnOlderRemoteArrives() async {
        let store = ComparisonRoundStore(directory: directory)
        let adapter = MacComparisonSyncAdapter(store: store, defaults: defaults)
        var local = makeRound(offset: 0)
        local.updatedAt = local.createdAt.addingTimeInterval(100)
        store.upsert(local)
        await adapter.didAcknowledgeSyncedRounds(ids: [local.id])

        var stale = local
        stale.updatedAt = local.createdAt
        await adapter.didReceiveRemoteRound(stale)

        XCTAssertEqual(store.round(id: local.id)?.updatedAt, local.updatedAt)
        XCTAssertEqual(adapter.pendingRounds().map(\.id), [local.id])
    }

    func testRemoteDeletion_removesLocally() async {
        let store = ComparisonRoundStore(directory: directory)
        let adapter = MacComparisonSyncAdapter(store: store, defaults: defaults)
        let round = makeRound(offset: 0)
        store.upsert(round)

        await adapter.didDeleteRemoteRound(id: round.id)

        XCTAssertTrue(store.rounds.isEmpty)
        XCTAssertTrue(adapter.pendingRounds().isEmpty)
    }

    func testReJudgedRound_becomesPendingAgain() async {
        let store = ComparisonRoundStore(directory: directory)
        let adapter = MacComparisonSyncAdapter(store: store, defaults: defaults)
        var round = makeRound(offset: 0)
        store.upsert(round)
        await adapter.didAcknowledgeSyncedRounds(ids: [round.id])
        XCTAssertTrue(adapter.pendingRounds().isEmpty)

        XCTAssertTrue(round.judge(rankings: round.entries.enumerated().map {
            ModelComparisonRanking(entryID: $1.id, rank: $0 + 1)
        }))
        store.upsert(round)

        XCTAssertEqual(adapter.pendingRounds().map(\.id), [round.id])
    }

    private func makeRound(offset: TimeInterval) -> ModelComparisonRound {
        let entries = ["a", "b"].map {
            ModelComparisonEntry(modelID: $0, modelDisplayName: $0, providerDisplayName: "P", transcript: "t")
        }
        return ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            inputMode: .streaming,
            sample: ModelComparisonSample(name: "s", contentHash: nil, durationSeconds: 1),
            language: nil,
            originPlatform: "macos",
            entries: entries,
            blindOrder: entries.map(\.id)
        )
    }
}
