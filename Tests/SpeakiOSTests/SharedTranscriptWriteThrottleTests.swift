import Foundation
import XCTest
@testable import SpeakiOSLib

final class SharedTranscriptWriteThrottleTests: XCTestCase {
    func testFirstPartialIsAlwaysAdmitted() {
        var throttle = SharedTranscriptWriteThrottle()
        XCTAssertTrue(throttle.admit(at: Date(timeIntervalSince1970: 0)))
    }

    func testPartialsWithinTheIntervalAreRefusedUntilItElapses() {
        var throttle = SharedTranscriptWriteThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.admit(at: start))
        XCTAssertFalse(throttle.admit(at: start.addingTimeInterval(0.5)))
        XCTAssertFalse(throttle.admit(at: start.addingTimeInterval(0.999)))
        XCTAssertTrue(throttle.admit(at: start.addingTimeInterval(SharedTranscriptWriteThrottle.interval)))
        XCTAssertFalse(throttle.admit(at: start.addingTimeInterval(1.5)))
    }

    func testRefusedPartialDoesNotPostponeTheNextSlot() {
        var throttle = SharedTranscriptWriteThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.admit(at: start))
        XCTAssertFalse(throttle.admit(at: start.addingTimeInterval(0.9)))
        XCTAssertTrue(throttle.admit(at: start.addingTimeInterval(1.0)))
    }

    func testResetAdmitsANewRunsFirstPartialImmediately() {
        var throttle = SharedTranscriptWriteThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.admit(at: start))
        throttle.reset()
        XCTAssertTrue(throttle.admit(at: start.addingTimeInterval(0.1)))
    }
}
