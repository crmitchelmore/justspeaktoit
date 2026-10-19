import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopComparisonImportBudgetTests: XCTestCase {
    func testCompletedMetadataConsumesItsAllowanceAndOverBudgetGrowthRollsBack() throws {
        let round = pending()
        let initial = try DesktopComparisonImportBudget.metadataBytes(round)
            + DesktopComparisonImportBudget.margin(round.entries.count) + 44
        let staging = DesktopComparisonStaging(limit: initial)
        let budget = try DesktopComparisonImportBudget(round: round, audioBytes: 44, staging: staging)
        var first = round.entries[0]
        first.transcript = "Raw."
        try budget.record(first)
        XCTAssertLessThan(staging.byteCount, initial)
        let before = staging.byteCount
        var second = round.entries[1]
        second.transcript = String(repeating: "x", count: 10_000)
        XCTAssertThrowsError(try budget.record(second))
        XCTAssertEqual(staging.byteCount, before)
        second.transcript = "Recovery."
        try budget.record(second)
        var completed = round
        completed.entries = [first, second]
        try budget.finish(completed)
        XCTAssertEqual(staging.byteCount, 44 + (try DesktopComparisonImportBudget.metadataBytes(completed)))
        staging.releaseOwners([round.id])
        XCTAssertEqual(staging.byteCount, 0)
    }

    func testDuplicateOrUnknownResultsCannotDoubleReleaseMetadataAllowance() throws {
        let round = pending()
        let staging = DesktopComparisonStaging()
        let budget = try DesktopComparisonImportBudget(round: round, audioBytes: 44, staging: staging)
        try budget.record(round.entries[0])
        let before = staging.byteCount
        XCTAssertThrowsError(try budget.record(round.entries[0]))
        let unknown = ModelComparisonEntry(modelID: "other", modelDisplayName: "Other", providerDisplayName: "Test")
        XCTAssertThrowsError(try budget.record(unknown))
        XCTAssertEqual(staging.byteCount, before)
    }

    private func pending() -> ModelComparisonRound {
        let entries = ["first", "second"].map {
            ModelComparisonEntry(modelID: $0, modelDisplayName: $0, providerDisplayName: "Synthetic")
        }
        return ModelComparisonRound(
            inputMode: .file, sample: .init(name: "Synthetic", contentHash: nil, durationSeconds: 1),
            language: nil, originPlatform: "test", entries: entries, blindOrder: entries.map(\.id)
        )
    }
}
