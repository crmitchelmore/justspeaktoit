#if os(macOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

/// The race between a running command and the caller's deadline (issue #793):
/// `AutomationServerTests.testRequest_isAnsweredOverTheSocket` failed on CI in
/// under a second with a well-formed `timed_out` reply for a command that had
/// already finished. The work task cancelled the timer before settling the
/// gate, so on a starved runner the woken timer could reach the gate first.
final class AutomationDeadlineTests: XCTestCase {
    func testCommandThatFinishesFirst_isNeverReportedAsTimedOut() async {
        // Many iterations: the bug was a scheduling race, so one exchange would
        // prove nothing. With the result settling the gate before the timer is
        // cancelled, no iteration can see the deadline win.
        for iteration in 0..<300 {
            let work = Task<AutomationResponse, Never> {
                .success(id: "fast", command: .status, result: AutomationResult(text: "done"))
            }
            let response = await AutomationDeadline.value(of: work, within: 30, id: "fast", command: .status)

            XCTAssertTrue(
                response.ok,
                "Iteration \(iteration): a finished command was reported as \(String(describing: response.error))"
            )
            XCTAssertEqual(response.result?.text, "done")
            if !response.ok { break }
        }
    }

    func testExpiredDeadline_answersAtTheDeadlineWithoutAbandoningTheCommand() async {
        let finished = expectation(description: "command still runs to completion")
        let work = Task<AutomationResponse, Never> {
            try? await Task.sleep(for: .seconds(1))
            finished.fulfill()
            return .success(id: "slow", command: .stopDictation, result: AutomationResult(text: "late"))
        }

        let clock = ContinuousClock()
        let started = clock.now
        let response = await AutomationDeadline.value(of: work, within: 0.2, id: "slow", command: .stopDictation)
        let elapsed = clock.now - started

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "slow")
        XCTAssertEqual(response.command, .stopDictation)
        XCTAssertEqual(response.error?.code, .timedOut)
        XCTAssertLessThan(elapsed, .seconds(0.9), "The timeout must be answered at the deadline, not after the command")

        // The late result settles an already-answered gate: a no-op, not a second resume.
        await fulfillment(of: [finished], timeout: 5)
        let late = await work.value
        XCTAssertEqual(late.result?.text, "late")
    }
}
#endif
