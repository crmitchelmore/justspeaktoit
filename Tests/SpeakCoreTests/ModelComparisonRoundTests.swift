import Foundation
import XCTest

@testable import SpeakCore

/// A deterministic generator so blind-order tests can pin the shuffle.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

enum ModelComparisonFixtures {
    static func entry(_ model: String, transcript: String = "hello world") -> ModelComparisonEntry {
        ModelComparisonEntry(
            modelID: model,
            modelDisplayName: model.uppercased(),
            providerDisplayName: "Provider",
            transcript: transcript
        )
    }

    static func round(
        entries: [ModelComparisonEntry],
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        seed: UInt64 = 7
    ) -> ModelComparisonRound {
        var generator = SeededGenerator(seed: seed)
        return ModelComparisonRound(
            createdAt: createdAt,
            inputMode: .file,
            sample: ModelComparisonSample(name: "clip.wav", contentHash: "abc123", durationSeconds: 12.5),
            language: "en",
            originPlatform: "macos",
            entries: entries,
            blindOrder: ModelComparisonRound.makeBlindOrder(for: entries, using: &generator)
        )
    }
}

final class ModelComparisonRoundTests: XCTestCase {
    func testBlindOrder_isAPermutationOfEveryEntryAndFollowsTheGenerator() {
        let entries = (0..<5).map { ModelComparisonFixtures.entry("m\($0)") }
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        var other = SeededGenerator(seed: 43)

        let orderA = ModelComparisonRound.makeBlindOrder(for: entries, using: &first)
        let orderB = ModelComparisonRound.makeBlindOrder(for: entries, using: &second)
        let orderC = ModelComparisonRound.makeBlindOrder(for: entries, using: &other)

        XCTAssertEqual(Set(orderA), Set(entries.map(\.id)))
        XCTAssertEqual(orderA, orderB, "The same seed must give the same blind order")
        XCTAssertNotEqual(orderA, orderC, "A different seed should reorder five entries")
    }

    func testInvalidBlindOrderIsRejected() throws {
        let entries = (0..<3).map { ModelComparisonFixtures.entry("m\($0)") }
        let round = ModelComparisonRound(
            inputMode: .streaming,
            sample: ModelComparisonSample(name: "x", contentHash: nil, durationSeconds: 1),
            language: nil,
            originPlatform: "macos",
            entries: entries,
            blindOrder: [entries[2].id]
        )

        XCTAssertFalse(round.isValid)
        XCTAssertTrue(round.entriesInBlindOrder.isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(ModelComparisonRound.self, from: JSONEncoder().encode(round)))

    }

    func testDuplicateEntryIDsAreRejectedWithoutDictionaryTrap() throws {
        let entry = ModelComparisonFixtures.entry("same")
        let round = ModelComparisonFixtures.round(entries: [entry, entry])
        XCTAssertFalse(round.isValid)
        XCTAssertTrue(round.entriesInBlindOrder.isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(ModelComparisonRound.self, from: JSONEncoder().encode(round)))
    }

    func testFailedEntryCanBeRankedAlongsideSuccessfulEntries() {
        var entries = (0..<3).map { ModelComparisonFixtures.entry("m\($0)") }
        entries[2].errorDescription = "failed"
        var round = ModelComparisonFixtures.round(entries: entries)
        XCTAssertTrue(round.judge(rankings: entries.enumerated().map {
            ModelComparisonRanking(entryID: $1.id, rank: $0 + 1)
        }))
        XCTAssertTrue(round.isJudged)
    }

    func testBlindLabels_runAThroughZThenWrap() {
        XCTAssertEqual(ModelComparisonRound.blindLabel(at: 0), "A")
        XCTAssertEqual(ModelComparisonRound.blindLabel(at: 25), "Z")
        XCTAssertEqual(ModelComparisonRound.blindLabel(at: 26), "A2")
        XCTAssertEqual(ModelComparisonRound.blindLabel(at: -1), "?")
    }

    func testJudge_rejectsIncompleteOrDuplicateRankings() {
        let entries = (0..<3).map { ModelComparisonFixtures.entry("m\($0)") }
        var round = ModelComparisonFixtures.round(entries: entries)

        XCTAssertFalse(round.judge(rankings: [
            ModelComparisonRanking(entryID: entries[0].id, rank: 1),
            ModelComparisonRanking(entryID: entries[1].id, rank: 2)
        ]), "A missing entry is not a complete ranking")
        XCTAssertFalse(round.judge(rankings: [
            ModelComparisonRanking(entryID: entries[0].id, rank: 1),
            ModelComparisonRanking(entryID: entries[1].id, rank: 1),
            ModelComparisonRanking(entryID: entries[2].id, rank: 3)
        ]), "Duplicate ranks are not a permutation")
        XCTAssertFalse(round.judge(rankings: [
            ModelComparisonRanking(entryID: entries[0].id, rank: 0),
            ModelComparisonRanking(entryID: entries[1].id, rank: 1),
            ModelComparisonRanking(entryID: entries[2].id, rank: 2)
        ]), "Ranks start at 1")
        XCTAssertFalse(round.isJudged)
        XCTAssertNil(round.judgedAt)
    }

    func testJudge_storesASortedRankingAndBumpsUpdatedAt() {
        let entries = (0..<3).map { ModelComparisonFixtures.entry("m\($0)") }
        var round = ModelComparisonFixtures.round(entries: entries)
        let judgedAt = round.createdAt.addingTimeInterval(60)

        XCTAssertTrue(round.judge(rankings: [
            ModelComparisonRanking(entryID: entries[2].id, rank: 3),
            ModelComparisonRanking(entryID: entries[0].id, rank: 1),
            ModelComparisonRanking(entryID: entries[1].id, rank: 2)
        ], at: judgedAt))

        XCTAssertTrue(round.isJudged)
        XCTAssertEqual(round.rankings?.map(\.rank), [1, 2, 3])
        XCTAssertEqual(round.rank(for: entries[2].id), 3)
        XCTAssertEqual(round.judgedAt, judgedAt)
        XCTAssertEqual(round.updatedAt, judgedAt)
    }

    func testRound_roundTripsThroughJSONWithTheBlindOrderIntact() throws {
        let entries = (0..<4).map { ModelComparisonFixtures.entry("m\($0)", transcript: "t\($0)") }
        var round = ModelComparisonFixtures.round(entries: entries)
        round.entries[1].timeToFirstPartialMs = 320
        round.entries[1].estimatedCostUSD = Decimal(string: "0.0012")
        round.entries[3].errorDescription = "timed out"
        _ = round.judge(rankings: entries.enumerated().map { ModelComparisonRanking(entryID: $1.id, rank: $0 + 1) })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelComparisonRound.self, from: try encoder.encode(round))

        XCTAssertEqual(decoded.blindOrder, round.blindOrder)
        XCTAssertEqual(decoded.rankings, round.rankings)
        XCTAssertEqual(decoded.entries[1].estimatedCostUSD, Decimal(string: "0.0012"))
        XCTAssertEqual(decoded.entries[3].errorDescription, "timed out")
        XCTAssertEqual(decoded.sample, round.sample)
        XCTAssertEqual(decoded.inputMode, .file)
    }
}
