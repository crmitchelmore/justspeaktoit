import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class ForegroundRecordingOwnershipTests: XCTestCase {
    func testStaleRelease_cannotFreeReplacementOwner() throws {
        let ownership = ForegroundRecordingOwnership()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(ownership.claim(first))
        XCTAssertFalse(ownership.claim(second))
        XCTAssertThrowsError(try ownership.requireUnowned())
        ownership.release(first)
        XCTAssertNoThrow(try ownership.requireUnowned())
        XCTAssertTrue(ownership.claim(second))
        ownership.release(first)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertThrowsError(try ownership.requireUnowned())
        ownership.release(second)
        XCTAssertNoThrow(try ownership.requireUnowned())
    }
}
