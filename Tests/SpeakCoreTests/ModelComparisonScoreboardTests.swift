import Foundation
import XCTest

@testable import SpeakCore

final class ModelComparisonScoreboardTests: XCTestCase {
    /// Three judged rounds over the same three models, matching the issue's
    /// "after three rounds the scoreboard shows an aggregate" acceptance.
    private func threeJudgedRounds() -> [ModelComparisonRound] {
        // Ranks per round for (alpha, beta, gamma).
        let outcomes: [[Int]] = [[1, 2, 3], [1, 3, 2], [2, 1, 3]]
        return outcomes.enumerated().map { index, ranks in
            var entries = [
                ModelComparisonFixtures.entry("alpha"),
                ModelComparisonFixtures.entry("beta"),
                ModelComparisonFixtures.entry("gamma")
            ]
            entries[0].timeToFirstPartialMs = 100 * (index + 1)
            entries[0].timeToFinalMs = 1_000
            entries[0].estimatedCostUSD = Decimal(string: "0.002")
            entries[1].timeToFinalMs = 2_000
            var round = ModelComparisonFixtures.round(
                entries: entries,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                seed: UInt64(index)
            )
            XCTAssertTrue(round.judge(rankings: zip(entries, ranks).map {
                ModelComparisonRanking(entryID: $0.id, rank: $1)
            }))
            return round
        }
    }

    func testScores_aggregateWinsMeanRankLatencyAndCostAcrossRounds() {
        let scores = ModelComparisonScoreboard.scores(for: threeJudgedRounds())
        let byID = Dictionary(uniqueKeysWithValues: scores.map { ($0.modelID, $0) })

        XCTAssertEqual(scores.map(\.modelID), ["alpha", "beta", "gamma"], "Best mean rank first")
        XCTAssertEqual(byID["alpha"]?.roundsPlayed, 3)
        XCTAssertEqual(byID["alpha"]?.wins, 2)
        XCTAssertEqual(byID["alpha"]?.meanRank, 4.0 / 3.0)
        XCTAssertEqual(byID["alpha"]?.meanTimeToFirstPartialMs, 200)
        XCTAssertEqual(byID["alpha"]?.meanTimeToFinalMs, 1_000)
        XCTAssertEqual(byID["alpha"]?.meanEstimatedCostUSD, Decimal(string: "0.002"))
        XCTAssertEqual(byID["beta"]?.wins, 1)
        XCTAssertEqual(byID["beta"]?.meanRank, 2)
        XCTAssertNil(byID["beta"]?.meanTimeToFirstPartialMs)
        XCTAssertEqual(byID["gamma"]?.wins, 0)
        XCTAssertEqual(byID["gamma"]?.meanRank, 8.0 / 3.0)
        XCTAssertNil(byID["gamma"]?.meanEstimatedCostUSD)
        XCTAssertEqual(byID["alpha"]?.winRate, 2.0 / 3.0)
    }

    func testScores_countFailuresSeparatelyAndKeepUnjudgedRoundsOutOfRankStats() {
        var entries = [ModelComparisonFixtures.entry("alpha"), ModelComparisonFixtures.entry("beta")]
        entries[1].errorDescription = "boom"
        entries[1].transcript = ""
        entries[0].timeToFinalMs = 500
        let unjudged = ModelComparisonFixtures.round(entries: entries)

        let scores = ModelComparisonScoreboard.scores(for: [unjudged])
        let byID = Dictionary(uniqueKeysWithValues: scores.map { ($0.modelID, $0) })

        XCTAssertEqual(byID["alpha"]?.roundsPlayed, 0)
        XCTAssertNil(byID["alpha"]?.meanRank)
        XCTAssertEqual(byID["alpha"]?.meanTimeToFinalMs, 500, "Latency counts even before judging")
        XCTAssertEqual(byID["beta"]?.failures, 1)
        XCTAssertEqual(byID["beta"]?.roundsPlayed, 0)
    }

    func testStandingOrder_prefersEvidenceOverASingleLuckyWin() {
        let consistent = ModelComparisonScore(
            modelID: "a", modelDisplayName: "A", providerDisplayName: "P",
            roundsPlayed: 4, wins: 3, meanRank: 1.25, failures: 0,
            meanTimeToFirstPartialMs: nil, meanTimeToFinalMs: nil, meanEstimatedCostUSD: nil
        )
        let lucky = ModelComparisonScore(
            modelID: "b", modelDisplayName: "B", providerDisplayName: "P",
            roundsPlayed: 1, wins: 1, meanRank: 1.0, failures: 0,
            meanTimeToFirstPartialMs: nil, meanTimeToFinalMs: nil, meanEstimatedCostUSD: nil
        )
        let unranked = ModelComparisonScore(
            modelID: "c", modelDisplayName: "C", providerDisplayName: "P",
            roundsPlayed: 0, wins: 0, meanRank: nil, failures: 2,
            meanTimeToFirstPartialMs: nil, meanTimeToFinalMs: nil, meanEstimatedCostUSD: nil
        )

        // Mean rank is the primary key, so a perfect single round still leads;
        // the tie-breakers only apply between equal means.
        XCTAssertTrue(ModelComparisonScoreboard.standingOrder(lucky, consistent))
        XCTAssertTrue(ModelComparisonScoreboard.standingOrder(consistent, unranked))
        XCTAssertFalse(ModelComparisonScoreboard.standingOrder(unranked, lucky))

        let tiedFewer = ModelComparisonScore(
            modelID: "d", modelDisplayName: "D", providerDisplayName: "P",
            roundsPlayed: 2, wins: 1, meanRank: 1.25, failures: 0,
            meanTimeToFirstPartialMs: nil, meanTimeToFinalMs: nil, meanEstimatedCostUSD: nil
        )
        XCTAssertTrue(ModelComparisonScoreboard.standingOrder(consistent, tiedFewer), "More wins breaks a tie")
    }

    func testScores_useTheLatestDisplayNames() {
        var first = ModelComparisonFixtures.round(entries: [ModelComparisonFixtures.entry("alpha")])
        first.entries[0] = ModelComparisonEntry(
            id: first.entries[0].id, modelID: "alpha", modelDisplayName: "Old", providerDisplayName: "P"
        )
        var second = ModelComparisonFixtures.round(
            entries: [ModelComparisonEntry(modelID: "alpha", modelDisplayName: "New", providerDisplayName: "P")],
            createdAt: first.createdAt.addingTimeInterval(1)
        )
        _ = second.judge(rankings: [ModelComparisonRanking(entryID: second.entries[0].id, rank: 1)])

        let scores = ModelComparisonScoreboard.scores(for: [first, second])
        XCTAssertEqual(scores.first?.modelDisplayName, "New")
    }
}
