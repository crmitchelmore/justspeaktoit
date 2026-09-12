import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class ComparisonRoundStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonRoundStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testUpsert_persistsNewestFirstAndReloads() throws {
        let store = ComparisonRoundStore(directory: directory)
        let older = makeRound(offset: 0)
        let newer = makeRound(offset: 60)
        var upserted: [UUID] = []
        store.onRoundUpserted = { upserted.append($0.id) }

        store.upsert(older)
        store.upsert(newer)

        XCTAssertEqual(store.rounds.map(\.id), [newer.id, older.id])
        XCTAssertEqual(upserted, [older.id, newer.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))

        let reloaded = ComparisonRoundStore(directory: directory)
        XCTAssertEqual(reloaded.rounds, [newer, older])
    }

    func testRemove_dropsTheRoundAndNotifies() {
        let store = ComparisonRoundStore(directory: directory)
        let round = makeRound(offset: 0)
        var removed: [UUID] = []
        store.onRoundRemoved = { removed.append($0) }
        store.upsert(round)

        store.remove(id: round.id)
        store.remove(id: round.id)

        XCTAssertTrue(store.rounds.isEmpty)
        XCTAssertEqual(removed, [round.id], "A second removal of the same id is a no-op")
    }

    func testApplyRemote_isLastWriterWinsAndNeverEchoes() {
        let store = ComparisonRoundStore(directory: directory)
        var echoed = 0
        store.onRoundUpserted = { _ in echoed += 1 }
        store.onRoundRemoved = { _ in echoed += 1 }
        let local = makeRound(offset: 0)
        store.upsert(local)
        echoed = 0

        var stale = local
        stale.updatedAt = local.updatedAt.addingTimeInterval(-10)
        stale.entries[0].transcript = "stale"
        XCTAssertFalse(store.applyRemote(stale))
        XCTAssertEqual(store.round(id: local.id)?.entries[0].transcript, local.entries[0].transcript)

        var fresh = local
        fresh.updatedAt = local.updatedAt.addingTimeInterval(10)
        fresh.entries[0].transcript = "fresh"
        XCTAssertTrue(store.applyRemote(fresh))
        XCTAssertEqual(store.round(id: local.id)?.entries[0].transcript, "fresh")

        store.removeRemote(id: local.id)
        XCTAssertTrue(store.rounds.isEmpty)
        XCTAssertEqual(echoed, 0, "Remote changes must not be uploaded back")
    }

    func testCorruptFile_isReportedNotFatal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("rounds.json"))

        let store = ComparisonRoundStore(directory: directory)

        XCTAssertTrue(store.rounds.isEmpty)
        XCTAssertNotNil(store.persistenceError)
    }

    private func makeRound(offset: TimeInterval) -> ModelComparisonRound {
        let entries = ["a", "b"].map {
            ModelComparisonEntry(modelID: $0, modelDisplayName: $0, providerDisplayName: "P", transcript: "t")
        }
        return ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            inputMode: .file,
            sample: ModelComparisonSample(name: "s", contentHash: nil, durationSeconds: 1),
            language: nil,
            originPlatform: "macos",
            entries: entries,
            blindOrder: entries.map(\.id)
        )
    }
}
