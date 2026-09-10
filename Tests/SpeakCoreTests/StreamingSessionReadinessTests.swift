import Foundation
import XCTest

@testable import SpeakCore

/// The two mechanisms every streaming client here shares: the handshake gate a
/// graceful finish waits on, and the ceiling on outbound audio a stalled socket
/// would otherwise retain without bound.
final class StreamingSessionReadinessTests: XCTestCase {
    func testWaitUntilReady_returnsImmediatelyWhenTheSessionIsAlreadyReady() {
        let readiness = StreamingSessionReadiness()
        readiness.markReady()

        let started = Date()
        XCTAssertTrue(readiness.waitUntilReady(budget: 5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// The point of the whole mechanism: a stop that lands during the handshake
    /// waits for the ready frame instead of throwing the capture away.
    func testWaitUntilReady_isReleasedByAReadyFrameThatArrivesDuringTheWait() {
        let readiness = StreamingSessionReadiness()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            readiness.markReady()
        }

        XCTAssertTrue(readiness.waitUntilReady(budget: 5))
        XCTAssertTrue(readiness.isReady)
    }

    func testWaitUntilReady_givesUpWhenTheSessionNeverBecomesReady() {
        let readiness = StreamingSessionReadiness()

        let started = Date()
        XCTAssertFalse(readiness.waitUntilReady(budget: 0.1))
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the wait must be bounded by its budget"
        )
        XCTAssertFalse(readiness.isReady)
    }

    /// A waiter must never outlive the session it belongs to.
    func testReset_releasesAWaiterAndClearsReadiness() {
        let readiness = StreamingSessionReadiness()
        readiness.markReady()
        XCTAssertTrue(readiness.isReady)

        readiness.reset()
        XCTAssertFalse(readiness.isReady)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            readiness.reset()
        }
        XCTAssertFalse(readiness.waitUntilReady(budget: 5))
    }

    // MARK: - Outbound audio budget

    func testSendBudget_admitsAudioUntilTheCeilingAndThenRefuses() {
        // 16 kHz PCM16 for one second, so the ceiling is a known byte count.
        let budget = StreamingAudioSendBudget(sampleRate: 16_000, seconds: 1)
        let frameBytes = 3_200

        for _ in 0..<10 {
            XCTAssertTrue(budget.admit(frameBytes))
        }
        XCTAssertEqual(budget.inFlightBytes, 32_000)
        // The eleventh frame would exceed one second of audio in flight, which
        // is the evidence that the socket has stopped making progress.
        XCTAssertFalse(budget.admit(frameBytes))
    }

    func testSendBudget_admitsAgainOnceCompletionsRelease() {
        let budget = StreamingAudioSendBudget(sampleRate: 16_000, seconds: 1)
        while budget.admit(3_200) {}

        budget.release(3_200)
        XCTAssertTrue(budget.admit(3_200))
    }

    func testSendBudget_resetsForANewSession() {
        let budget = StreamingAudioSendBudget(sampleRate: 16_000, seconds: 1)
        while budget.admit(3_200) {}
        XCTAssertFalse(budget.admit(3_200))

        budget.reset()
        XCTAssertEqual(budget.inFlightBytes, 0)
        XCTAssertTrue(budget.admit(3_200))
    }

    func testSendBudget_neverGoesNegativeOnAnExtraRelease() {
        let budget = StreamingAudioSendBudget(sampleRate: 16_000, seconds: 1)
        budget.release(9_999)
        XCTAssertEqual(budget.inFlightBytes, 0)
    }

    /// A stalled transport is reported, not absorbed: the audio already sent is
    /// not being transcribed, and holding the rest would only grow the failure.
    func testTransportStalled_readsAsSomethingAUserCanActOn() throws {
        let message = try XCTUnwrap(
            StreamingClientError.transportStalled(provider: "Speechmatics").errorDescription
        )
        XCTAssertTrue(message.contains("Speechmatics"), message)
        XCTAssertTrue(message.lowercased().contains("audio"), message)
    }
}
