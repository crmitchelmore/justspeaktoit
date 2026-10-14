import Foundation
import SpeakDesktop
import XCTest

final class DesktopNativeClipboardReadTests: XCTestCase {
    func testOnlyGenuinelyAbsentStatusReturnsNil() throws {
        XCTAssertNil(try DesktopNativeClipboardRead.result(status: 1, text: [], error: ""))
        XCTAssertEqual(try DesktopNativeClipboardRead.result(status: 0, text: [0], error: ""), "")
        XCTAssertEqual(try DesktopNativeClipboardRead.result(status: 0, text: [65, 0], error: ""), "A")
        for status: Int32 in [2, 3, 4, 5, 6, 7, -1, 99] {
            XCTAssertThrowsError(try DesktopNativeClipboardRead.result(
                status: status, text: [0], error: "Synthetic native failure"
            ))
        }
    }

    func testStatusContractPreservesCancellationAndExplicitFailures() {
        for (status, expected): (Int32, DesktopClipboardReadError) in [
            (2, .tooLarge), (3, .invalidText), (4, .timedOut), (7, .busy),
            (6, .unsupported("Synthetic unavailable display")), (-1, .nativeFailure("Synthetic unavailable display"))
        ] {
            XCTAssertThrowsError(try DesktopNativeClipboardRead.result(
                status: status, text: [], error: "Synthetic unavailable display"
            )) { XCTAssertEqual($0 as? DesktopClipboardReadError, expected) }
        }
        XCTAssertThrowsError(try DesktopNativeClipboardRead.result(status: 5, text: [], error: "")) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testMalformedOrUnterminatedNativeTextFailsInsteadOfBeingRepaired() {
        for text: [CChar] in [[], [65], [-1, 0]] {
            XCTAssertThrowsError(try DesktopNativeClipboardRead.result(status: 0, text: text, error: "")) {
                XCTAssertEqual($0 as? DesktopClipboardReadError, .invalidText)
            }
        }
    }

    func testCancellationOwnsAndDrainsTheNativeRequest() async {
        await assertCancellation(failure: nil)
    }

    func testCancellationTakesPrecedenceOverALateNativeFailure() async {
        await assertCancellation(failure: .nativeFailure("LATE SYNTHETIC ERROR"))
    }

    private func assertCancellation(failure: DesktopClipboardReadError?) async {
        let entered = expectation(description: "Synthetic blocking read entered")
        let request = SyntheticClipboardReadRequest(failure: failure, entered: { entered.fulfill() })
        let task = Task { try await DesktopNativeClipboardRead.read(request) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled native request cannot return late text")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(request.wasCancelled)
    }
}

private final class SyntheticClipboardReadRequest: DesktopNativeClipboardReadRequest, @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private let failure: DesktopClipboardReadError?
    private let entered: @Sendable () -> Void

    init(failure: DesktopClipboardReadError?, entered: @escaping @Sendable () -> Void) {
        self.failure = failure
        self.entered = entered
    }

    var wasCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func run() throws -> String? {
        condition.lock()
        defer { condition.unlock() }
        entered()
        let deadline = Date().addingTimeInterval(2)
        while !cancelled && condition.wait(until: deadline) {}
        if !cancelled { throw DesktopClipboardReadError.timedOut }
        if let failure { throw failure }
        return "LATE SYNTHETIC TEXT"
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
