#if os(iOS)
import SpeakCore
import UIKit
import XCTest
@testable import SpeakiOSLib

@MainActor
final class HandsFreeCaptureFinalisationTests: XCTestCase {
    func testNormalDrain_preservesResultAndEndsAssertionOnce() async throws {
        var ends = 0
        let owner = HandsFreeCaptureFinalisation(makeAssertion: {
            BackgroundTaskAssertion(name: "test", begin: { _, _ in .init(rawValue: 42) }, end: { _ in ends += 1 })
        })
        let result = try await owner.run(operation: { self.result("Final words") }, cancelCapture: {
            XCTFail("Successful finalisation must not cancel")
        })
        XCTAssertEqual(result.text, "Final words")
        XCTAssertEqual(ends, 1)
    }

    func testExpiry_returnsWhileProviderSuspendedAndIgnoresItsLateResult() async {
        var expire: (@MainActor @Sendable () -> Void)?
        var drain: CheckedContinuation<TranscriptionResult, Never>?
        var ends = 0
        var cancellations = 0
        let started = expectation(description: "provider draining")
        let owner = HandsFreeCaptureFinalisation(makeAssertion: {
            BackgroundTaskAssertion(name: "test", begin: { _, expiration in
                expire = expiration
                return .init(rawValue: 42)
            }, end: { _ in ends += 1 })
        })
        let task = Task {
            try await owner.run(operation: {
                await withCheckedContinuation { continuation in
                    drain = continuation
                    started.fulfill()
                }
            }, cancelCapture: { cancellations += 1 })
        }
        await fulfillment(of: [started], timeout: 2)
        expire?()
        do {
            _ = try await task.value
            XCTFail("Expiration must report incomplete finalisation")
        } catch {
            XCTAssertTrue(error is HandsFreeCaptureFinalisation.Failure)
        }
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(ends, 1)
        drain?.resume(returning: result("Late words"))
        await Task { @MainActor in }.value
        expire?()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(ends, 1)
    }

    func testDeadline_boundsProviderThatDoesNotFinish() async {
        var drain: CheckedContinuation<TranscriptionResult, Never>?
        var cancellations = 0
        let owner = HandsFreeCaptureFinalisation(timeout: .milliseconds(20), makeAssertion: {
            BackgroundTaskAssertion(name: "test", begin: { _, _ in .init(rawValue: 42) }, end: { _ in })
        })
        do {
            _ = try await owner.run(operation: {
                await withCheckedContinuation { drain = $0 }
            }, cancelCapture: { cancellations += 1 })
            XCTFail("Deadline must expire")
        } catch {
            XCTAssertTrue(error is HandsFreeCaptureFinalisation.Failure)
        }
        XCTAssertEqual(cancellations, 1)
        drain?.resume(returning: result(""))
    }

    func testExplicitCancellation_releasesProviderWithoutWaitingForItsResult() async {
        var drain: CheckedContinuation<TranscriptionResult, Never>?
        var cancellations = 0
        let started = expectation(description: "provider draining")
        let owner = HandsFreeCaptureFinalisation(makeAssertion: {
            BackgroundTaskAssertion(name: "test", begin: { _, _ in .init(rawValue: 42) }, end: { _ in })
        })
        let task = Task {
            try await owner.run(operation: {
                await withCheckedContinuation { continuation in
                    drain = continuation
                    started.fulfill()
                }
            }, cancelCapture: { cancellations += 1 })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Explicit cancellation must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellations, 1)
        drain?.resume(returning: result("Late words"))
    }

    private func result(_ text: String) -> TranscriptionResult {
        TranscriptionResult(text: text, segments: [], confidence: nil, duration: 1,
                            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil)
    }
}
#endif
