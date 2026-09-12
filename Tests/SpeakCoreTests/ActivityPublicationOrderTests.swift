import Foundation
import XCTest

@testable import SpeakCore

/// The Live Activity is reused across runs, so publication ordering and run
/// ownership decide whether proven capture can be overwritten by an older
/// state. The rule is a value type so it is exercised on every platform.
final class ActivityPublicationOrderTests: XCTestCase {
    func testNothingPublishesBeforeARunOpens() {
        var order = ActivityPublicationOrder()
        XCTAssertNil(order.currentRun)
        XCTAssertNil(order.submit())
    }

    func testNewestPublicationOfTheOwningRunApplies() {
        var order = ActivityPublicationOrder()
        order.beginRun()
        let newest = order.submit()
        XCTAssertNotNil(newest)
        XCTAssertTrue(order.isCurrent(newest!))
    }

    func testASupersededPublicationIsSkipped() {
        var order = ActivityPublicationOrder()
        order.beginRun()
        let arming = order.submit()!
        let recording = order.submit()!
        // `.arming` was submitted first; the capture-proof state supersedes it
        // even though ActivityKit may complete the two out of order.
        XCTAssertFalse(order.isCurrent(arming))
        XCTAssertTrue(order.isCurrent(recording))
    }

    func testAPriorRunsPublicationCannotOverwriteItsSuccessor() {
        var order = ActivityPublicationOrder()
        order.beginRun()
        let previousRunSnippet = order.submit()!
        order.beginRun()
        XCTAssertFalse(order.isCurrent(previousRunSnippet))
        let successorPreparation = order.submit()!
        XCTAssertTrue(order.isCurrent(successorPreparation))
        // Even once the successor's own publication has been applied, the
        // predecessor's deferred write stays superseded.
        XCTAssertFalse(order.isCurrent(previousRunSnippet))
    }

    func testBeginningARunSupersedesTheOutstandingLatestPublication() {
        var order = ActivityPublicationOrder()
        let first = order.beginRun()
        let latest = order.submit()!
        XCTAssertTrue(order.isCurrent(latest))
        order.beginRun()
        XCTAssertFalse(order.isCurrent(latest))
        XCTAssertFalse(order.owns(first))
    }

    func testRetiringBlocksEveryOutstandingAndFuturePublication() {
        var order = ActivityPublicationOrder()
        let run = order.beginRun()
        let pending = order.submit()!
        order.retire()
        XCTAssertFalse(order.isCurrent(pending))
        XCTAssertFalse(order.owns(run))
        XCTAssertNil(order.submit())
        XCTAssertNil(order.currentRun)
    }

    func testOwnershipTracksTheRunThatPrimedTheActivity() {
        var order = ActivityPublicationOrder()
        let priming = order.beginRun()
        XCTAssertTrue(order.owns(priming))
        // The priming continuation fires after a delay; a capture that started
        // in the meantime owns the activity instead.
        let capture = order.beginRun()
        XCTAssertFalse(order.owns(priming))
        XCTAssertTrue(order.owns(capture))
    }
}
