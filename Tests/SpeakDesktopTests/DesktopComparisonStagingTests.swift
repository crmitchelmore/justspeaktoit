import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopComparisonStagingTests: XCTestCase {
    func testProductionBudgetAcceptsExactlyEightHundredMillionBytesWithoutAllocation() throws {
        let staging = DesktopComparisonStaging()
        let first = UUID()
        let second = UUID()
        try staging.reserve(id: first, bytes: 799_999_999)
        try staging.reserve(id: second, bytes: 1)
        XCTAssertEqual(staging.byteCount, 800_000_000)
        XCTAssertThrowsError(try staging.reserve(id: second, bytes: 2))
        XCTAssertEqual(staging.byteCount, 800_000_000)
        staging.releaseOwners([first, second])
        XCTAssertEqual(staging.byteCount, 0)
    }

    func testExactBudgetBoundaryIncrementalGrowthAndRollbackAreAtomic() throws {
        let staging = DesktopComparisonStaging(limit: 100)
        let first = UUID()
        let second = UUID()
        try staging.reserve(id: first, bytes: 60)
        try staging.reserve(id: second, bytes: 40)
        XCTAssertEqual(staging.byteCount, 100)
        XCTAssertThrowsError(try staging.reserve(id: second, bytes: 41))
        XCTAssertEqual(staging.byteCount, 100)
        XCTAssertThrowsError(try staging.reserve(id: UUID(), bytes: Int.max))
        XCTAssertThrowsError(try staging.reserve(id: UUID(), bytes: -1))
        XCTAssertEqual(staging.byteCount, 100)
        staging.releaseOwners([first])
        XCTAssertEqual(staging.byteCount, 40)
        try staging.reserve(id: second, bytes: 100)
        XCTAssertEqual(staging.byteCount, 100)
        staging.releaseOwners([second])
        XCTAssertEqual(staging.byteCount, 0)
    }

    func testFrozenBytesRemainAccountedUntilEveryUnderlyingOperationExits() throws {
        let staging = DesktopComparisonStaging(limit: 100)
        let round = UUID()
        let first = UUID()
        let second = UUID()
        try staging.reserve(id: round, bytes: 100)
        try staging.retain(id: round, operation: first)
        try staging.retain(id: round, operation: second)
        staging.releaseOwners([round])
        staging.release(id: round, operation: first)
        XCTAssertEqual(staging.byteCount, 100)
        XCTAssertThrowsError(try staging.reserve(id: UUID(), bytes: 1))
        staging.release(id: round, operation: second)
        XCTAssertEqual(staging.byteCount, 0)
        staging.release(id: round, operation: second)
        XCTAssertEqual(staging.byteCount, 0)
    }

    func testScratchIsSeparatelySingleOwnedAndStaleReleaseCannotClearNewImport() throws {
        let staging = DesktopComparisonStaging()
        let first = try staging.beginScratch()
        XCTAssertThrowsError(try staging.beginScratch())
        staging.endScratch(first)
        let second = try staging.beginScratch()
        staging.endScratch(first)
        XCTAssertThrowsError(try staging.beginScratch())
        staging.endScratch(second)
        XCTAssertNoThrow(try staging.beginScratch())
        XCTAssertEqual(DesktopComparisonStaging.scratchBytes, 25_000_000)
        XCTAssertEqual(DesktopComparisonStaging.maximumBytes, 800_000_000)
    }
}
