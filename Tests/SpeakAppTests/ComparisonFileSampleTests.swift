import Foundation
import XCTest

@testable import SpeakApp

final class ComparisonFileSampleTests: XCTestCase {
    func testSample_whenCancelled_stopsReadingAndThrowsCancellation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonFileSampleTests-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 4 * 1_024 * 1_024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task.detached { () throws -> Void in
            // Cancel from inside so the sampler starts already cancelled,
            // independent of scheduling order.
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try ComparisonFileRunner.sample(for: url)
        }
        do {
            try await task.value
            XCTFail("A cancelled sample must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }
    }
}
