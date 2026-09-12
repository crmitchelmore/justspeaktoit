import CloudKit
import SpeakCore
import XCTest

@testable import SpeakSync

@MainActor
final class ComparisonSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "ComparisonSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: Record mapping

    func testRecord_roundTripsARoundThroughItsPayload() throws {
        var round = makeRound()
        _ = round.judge(rankings: round.entries.enumerated().map {
            ModelComparisonRanking(entryID: $1.id, rank: $0 + 1)
        }, at: round.createdAt.addingTimeInterval(5))

        let record = try ComparisonSyncRecord.record(from: round)
        XCTAssertEqual(record.recordType, "ModelComparisonRound")
        XCTAssertEqual(record.recordID, ComparisonSyncRecord.recordID(for: round.id))
        XCTAssertEqual(record.recordID.zoneID, SyncConfiguration.zoneID)
        XCTAssertEqual(record["schemaVersion"] as? Int, ModelComparisonRound.schemaVersion)
        XCTAssertEqual(record["updatedAt"] as? Date, round.updatedAt)

        let mapped = try XCTUnwrap(ComparisonSyncRecord.round(from: record))
        XCTAssertEqual(mapped, round)
        XCTAssertEqual(ComparisonSyncRecord.roundID(fromRecordName: record.recordID.recordName), round.id)
        XCTAssertNil(
            ComparisonSyncRecord.roundID(fromRecordName: UUID().uuidString),
            "History record names are not rounds"
        )
    }

    func testRecord_fromANewerSchemaOrOtherType_isSkipped() throws {
        let record = try ComparisonSyncRecord.record(from: makeRound())
        record["schemaVersion"] = ModelComparisonRound.schemaVersion + 1
        XCTAssertNil(ComparisonSyncRecord.round(from: record))

        let history = CKRecord(recordType: SyncConfiguration.recordType, recordID: record.recordID)
        history["payload"] = record["payload"]
        history["schemaVersion"] = ModelComparisonRound.schemaVersion
        XCTAssertNil(ComparisonSyncRecord.round(from: history))
    }

    // MARK: Engine

    func testSync_appliesRemoteChangesInOrderAndAdvancesTheToken() async {
        let remote = makeRound()
        var newer = remote
        newer.updatedAt = remote.updatedAt.addingTimeInterval(10)
        let transport = FakeComparisonTransport(pages: [
            ComparisonChangePage(
                changes: [.changed(remote), .changed(newer)],
                serverChangeTokenData: Data("t1".utf8),
                moreComing: true
            ),
            ComparisonChangePage(changes: [.deleted(UUID())], serverChangeTokenData: Data("t2".utf8), moreComing: false)
        ])
        let delegate = FakeComparisonDelegate()
        let engine = await makeEngine(transport: transport, delegate: delegate)

        await engine.sync()

        XCTAssertEqual(delegate.received.map(\.updatedAt), [newer.updatedAt], "Coalesced to the final event")
        XCTAssertEqual(delegate.deleted.count, 1)
        XCTAssertEqual(defaults.data(forKey: ComparisonSyncEngine.syncTokenKey), Data("t2".utf8))
        XCTAssertEqual(transport.requestedTokens, [nil, Data("t1".utf8)])
        XCTAssertNil(engine.lastError)
        XCTAssertNotNil(engine.lastSyncTime)
    }

    func testSync_uploadsPendingRoundsUntilAcknowledged() async {
        let pending = makeRound()
        let transport = FakeComparisonTransport(pages: [.empty])
        let delegate = FakeComparisonDelegate(pending: [pending])
        let engine = await makeEngine(transport: transport, delegate: delegate)

        await engine.sync()

        XCTAssertEqual(transport.uploaded.map(\.id), [pending.id])
        XCTAssertEqual(delegate.acknowledged, [pending.id])
        XCTAssertNil(engine.lastError)
    }

    func testSync_reportsAFailedUploadAndKeepsTheRoundPending() async {
        let pending = makeRound()
        let transport = FakeComparisonTransport(pages: [.empty], failUploads: true)
        let delegate = FakeComparisonDelegate(pending: [pending])
        let engine = await makeEngine(transport: transport, delegate: delegate)

        await engine.sync()

        XCTAssertTrue(delegate.acknowledged.isEmpty)
        XCTAssertNotNil(engine.lastError)
        XCTAssertEqual(delegate.pendingRounds().map(\.id), [pending.id])
    }

    func testSync_whenCloudIsUnavailable_doesNothing() async {
        let transport = FakeComparisonTransport(pages: [.empty])
        let delegate = FakeComparisonDelegate(pending: [makeRound()])
        let engine = ComparisonSyncEngine(transport: transport, defaults: defaults, cloudAvailability: { false })
        await engine.initialize(delegate: delegate)

        await engine.sync()

        XCTAssertTrue(transport.uploaded.isEmpty)
        XCTAssertTrue(transport.requestedTokens.isEmpty)
    }

    func testUpload_prefersANewerRemoteCopy() async {
        let local = makeRound()
        var remote = local
        remote.updatedAt = local.updatedAt.addingTimeInterval(60)
        let transport = FakeComparisonTransport(pages: [], newerRemote: [remote.id: remote])
        let delegate = FakeComparisonDelegate()
        let engine = await makeEngine(transport: transport, delegate: delegate)

        try? await engine.upload(round: local)

        XCTAssertEqual(delegate.received.map(\.updatedAt), [remote.updatedAt])
        XCTAssertEqual(delegate.acknowledged, [local.id])
    }

    // MARK: Helpers

    private func makeEngine(
        transport: FakeComparisonTransport,
        delegate: FakeComparisonDelegate
    ) async -> ComparisonSyncEngine {
        let engine = ComparisonSyncEngine(transport: transport, defaults: defaults, cloudAvailability: { true })
        await engine.initialize(delegate: delegate)
        return engine
    }

    private func makeRound() -> ModelComparisonRound {
        let entries = ["a", "b"].map {
            ModelComparisonEntry(modelID: $0, modelDisplayName: $0, providerDisplayName: "P", transcript: "text \($0)")
        }
        return ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            inputMode: .streaming,
            sample: ModelComparisonSample(name: "Capture.wav", contentHash: "ff", durationSeconds: 3),
            language: "en",
            originPlatform: "macos",
            entries: entries,
            blindOrder: entries.map(\.id).reversed()
        )
    }
}

@MainActor
private final class FakeComparisonTransport: ComparisonSyncTransport {
    private var pages: [ComparisonChangePage]
    private let failUploads: Bool
    private let newerRemote: [UUID: ModelComparisonRound]
    private(set) var requestedTokens: [Data?] = []
    private(set) var uploaded: [ModelComparisonRound] = []

    init(pages: [ComparisonChangePage], failUploads: Bool = false, newerRemote: [UUID: ModelComparisonRound] = [:]) {
        self.pages = pages
        self.failUploads = failUploads
        self.newerRemote = newerRemote
    }

    func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage {
        requestedTokens.append(tokenData)
        return pages.isEmpty ? .empty : pages.removeFirst()
    }

    func upload(rounds: [ModelComparisonRound]) async -> ComparisonUploadResult {
        uploaded.append(contentsOf: rounds)
        if failUploads {
            return ComparisonUploadResult(
                acknowledgedIDs: [],
                remoteRounds: [],
                failures: Dictionary(uniqueKeysWithValues: rounds.map { ($0.id, SyncError.encodingFailed) })
            )
        }
        return ComparisonUploadResult(
            acknowledgedIDs: Set(rounds.map(\.id)),
            remoteRounds: rounds.compactMap { newerRemote[$0.id] },
            failures: [:]
        )
    }

    func delete(roundID _: UUID) async throws {}
}

@MainActor
private final class FakeComparisonDelegate: ComparisonSyncDelegate {
    private var pending: [ModelComparisonRound]
    private(set) var received: [ModelComparisonRound] = []
    private(set) var deleted: [UUID] = []
    private(set) var acknowledged: Set<UUID> = []

    init(pending: [ModelComparisonRound] = []) {
        self.pending = pending
    }

    func pendingRounds() -> [ModelComparisonRound] { pending }

    func didReceiveRemoteRound(_ round: ModelComparisonRound) async {
        received.append(round)
    }

    func didDeleteRemoteRound(id: UUID) async {
        deleted.append(id)
    }

    func didAcknowledgeSyncedRounds(ids: Set<UUID>) async {
        acknowledged.formUnion(ids)
        pending.removeAll { ids.contains($0.id) }
    }
}
