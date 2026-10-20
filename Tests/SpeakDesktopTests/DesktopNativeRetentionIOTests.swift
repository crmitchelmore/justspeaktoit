import Foundation
@testable import SpeakDesktop
import XCTest

final class DesktopNativeRetentionIOTests: XCTestCase {
    func testOperationAndCloseFailure_PreserveBothTypedErrorsAndCloseOnce() throws {
        var closes = 0
        XCTAssertThrowsError(try DesktopNativeRetentionIO.perform(closing: {
            closes += 1
            throw RetentionIOFixtureError.close
        }, operation: { throw CancellationError() })) {
            let failure = $0 as? DesktopNativeRetentionCleanupFailure
            XCTAssertTrue(failure?.primaryError is CancellationError)
            XCTAssertEqual(failure?.cleanupError as? RetentionIOFixtureError, .close)
        }
        XCTAssertEqual(closes, 1)
    }

    func testCloseOnlyFailure_PreservesOriginalErrorAndNeverRetriesClose() throws {
        var closes = 0
        XCTAssertThrowsError(try DesktopNativeRetentionIO.perform(closing: {
            closes += 1
            throw RetentionIOFixtureError.close
        }, operation: { 42 })) {
            XCTAssertEqual($0 as? RetentionIOFixtureError, .close)
        }
        XCTAssertEqual(closes, 1)
    }

    func testOperationOnlyFailure_ClosesOnceAndPreservesOriginalError() throws {
        var closes = 0
        XCTAssertThrowsError(try DesktopNativeRetentionIO.perform(closing: {
            closes += 1
        }, operation: { throw RetentionIOFixtureError.operation })) {
            XCTAssertEqual($0 as? RetentionIOFixtureError, .operation)
        }
        XCTAssertEqual(closes, 1)
    }

    func testSuccessfulOperation_ClosesOnceAndReturnsResult() throws {
        var closes = 0
        let result = try DesktopNativeRetentionIO.perform(closing: { closes += 1 }, operation: { 42 })
        XCTAssertEqual(result, 42)
        XCTAssertEqual(closes, 1)
    }
}

private enum RetentionIOFixtureError: Error, Equatable { case operation, close }
