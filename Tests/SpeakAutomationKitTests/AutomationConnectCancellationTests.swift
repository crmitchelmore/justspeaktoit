#if canImport(Darwin)
import Darwin
import Foundation
import SpeakCore
import XCTest
@testable import SpeakAutomationKit

final class AutomationConnectCancellationTests: XCTestCase {
    func testCancellationDuringPendingConnect_DoesNotWaitForRequestDeadline() async throws {
        // Darwin can refuse a full AF_UNIX backlog immediately with ECONNREFUSED. Inject EAGAIN
        // against the real owned/configured socket to exercise the pending-connect retry boundary.
        let waiting = expectation(description: "owned connect reached pending retry wait")
        let returned = expectation(description: "owned connect cancelled promptly")
        let token = AutomationRequestCancellation()
        defer { token.cancel() }
        let client = UnixSocketAutomationClient(
            socketPath: "/unused-await-fixture.sock", onConnectWait: { waiting.fulfill() },
            connectAttempt: { descriptor in
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                XCTAssertNotEqual(fcntl(descriptor, F_GETFL) & O_NONBLOCK, 0)
                return EAGAIN
            }
        )
        let request = AutomationRequest(command: .awaitTranscript, timeout: 600, captureID: UUID().uuidString)
        let operation = Task.detached {
            defer { returned.fulfill() }
            do {
                _ = try client.send(request, cancellation: token)
                XCTFail("No app should answer this fixture")
            } catch { XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable) }
        }
        await fulfillment(of: [waiting], timeout: 2)
        token.cancel()
        await fulfillment(of: [returned], timeout: 2)
        // Cleanup never awaits an unbounded connect; only consume value after its completion receipt.
        _ = operation
    }
}
#endif
