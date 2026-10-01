import Foundation
import XCTest

@testable import SpeakApp

@MainActor
final class BoundedOperationTests: XCTestCase {
    func testTimeoutDoesNotDrainNonCooperativeOperation() async {
        var continuation: CheckedContinuation<Int, Never>?
        let result = await BoundedOperation.run(timeout: .milliseconds(50)) {
            await withCheckedContinuation { continuation = $0 }
        }
        XCTAssertNil(result)
        // Resume the deliberately non-cooperative work so the test leaks no task.
        continuation?.resume(returning: 42)
    }

    func testCancellationReleasesWaiterBeforeDeadline() async {
        let task = Task {
            await BoundedOperation.run(timeout: .seconds(30)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        task.cancel()
        let result = await task.value
        guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
    }
}
