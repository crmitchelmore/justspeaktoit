import Foundation
import SpeakDesktopHost
import XCTest

final class DesktopAPIKeyRequestsTests: XCTestCase {
    func testCancellation_KeepsAdmissionOwnedUntilWorkerSettles() async {
        let requests = DesktopAPIKeyRequests()
        let gate = APIKeyRequestGate()
        let entered = expectation(description: "request entered")
        let cancelled = expectation(description: "worker saw cancellation")
        let identifier = UUID()
        XCTAssertTrue(requests.start(identifier) {
            entered.fulfill()
            await gate.wait()
            if Task.isCancelled { cancelled.fulfill() }
        })
        await fulfillment(of: [entered], timeout: 3)
        requests.cancel(identifier)
        XCTAssertFalse(requests.start(UUID()) { XCTFail("Cancelled worker still owns admission") })
        await gate.release()
        await requests.drain()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertTrue(requests.start(UUID()) {})
        await requests.drain()
    }

    func testWrongRequestCannotCancel_AndStopPermanentlyClosesAdmission() async {
        let requests = DesktopAPIKeyRequests()
        let gate = APIKeyRequestGate()
        let entered = expectation(description: "request entered")
        let settled = expectation(description: "worker settled")
        XCTAssertTrue(requests.start(UUID()) {
            entered.fulfill()
            await gate.wait()
            XCTAssertFalse(Task.isCancelled)
            settled.fulfill()
        })
        await fulfillment(of: [entered], timeout: 3)
        requests.cancel(UUID())
        await gate.release()
        await requests.drain()
        await fulfillment(of: [settled], timeout: 3)
        requests.stop()
        XCTAssertFalse(requests.start(UUID()) { XCTFail("Stopped owner admitted work") })
    }

    func testStop_CancelsHeldWorkWithoutAdmittingAReplacement() async {
        let requests = DesktopAPIKeyRequests()
        let gate = APIKeyRequestGate()
        let entered = expectation(description: "request entered")
        XCTAssertTrue(requests.start(UUID()) {
            entered.fulfill()
            await gate.wait()
            XCTAssertTrue(Task.isCancelled)
        })
        await fulfillment(of: [entered], timeout: 3)
        requests.stop()
        XCTAssertFalse(requests.start(UUID()) {})
        await gate.release()
        await requests.drain()
        XCTAssertFalse(requests.start(UUID()) {})
    }
}

private actor APIKeyRequestGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
