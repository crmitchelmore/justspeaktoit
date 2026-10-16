import SpeakCore
import XCTest
@testable import SpeakDesktopHost

final class DesktopComparisonPresentationTests: XCTestCase {
    func testFewerThanTwoUsableResultsRevealEvidenceWithoutRankingOrScoreboardCredit() {
        let round = round(failed: [true, false])
        let state = DesktopComparisonRoundPresentation(round: round, busy: false)
        XCTAssertTrue(state.revealed)
        XCTAssertFalse(state.judgeable)
        XCTAssertTrue(state.suffix(for: round.entries[0], in: round).contains("unranked"))
        XCTAssertNil(round.rankings)
        let scores = ModelComparisonScoreboard.scores(for: [round])
        XCTAssertEqual(scores.count, 2)
        XCTAssertTrue(scores.allSatisfy { $0.roundsPlayed == 0 && $0.wins == 0 && $0.meanRank == nil })
        XCTAssertEqual(scores.reduce(0) { $0 + $1.failures }, 1)
    }

    func testTwoUsableResultsStayBlindAndAllFailuresRevealOnlyAfterExecution() {
        let ready = round(failed: [false, false])
        let state = DesktopComparisonRoundPresentation(round: ready, busy: false)
        XCTAssertFalse(state.revealed)
        XCTAssertTrue(state.judgeable)
        XCTAssertEqual(state.suffix(for: ready.entries[0], in: ready), "")
        let failed = round(failed: [true, true])
        XCTAssertFalse(DesktopComparisonRoundPresentation(round: failed, busy: true).revealed)
        XCTAssertTrue(DesktopComparisonRoundPresentation(round: failed, busy: false).revealed)
    }

    private func round(failed: [Bool]) -> ModelComparisonRound {
        let entries = failed.enumerated().map {
            ModelComparisonEntry(
                modelID: "synthetic/\($0.offset)", modelDisplayName: "Synthetic \($0.offset)",
                providerDisplayName: "Synthetic", transcript: "Synthetic text",
                errorDescription: $0.element ? "Synthetic failure" : nil
            )
        }
        return ModelComparisonRound(
            inputMode: .file, sample: .init(name: "synthetic.wav", contentHash: nil, durationSeconds: 1),
            language: nil, originPlatform: "synthetic", entries: entries, blindOrder: entries.map(\.id)
        )
    }
}
