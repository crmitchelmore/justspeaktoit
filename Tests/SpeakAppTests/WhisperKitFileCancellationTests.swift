import Foundation
import WhisperKit
import XCTest

@testable import SpeakApp

@MainActor
final class WhisperKitFileCancellationTests: XCTestCase {
    func testDeadlineStopsOwnedDecoderAtSupportedBoundaryAndPreservesAnotherRequest() async throws {
        let pipeline = try await CallbackFilePipeline(WhisperKitConfig(load: false, download: false))
        defer {
            _ = pipeline.boundary.finish()
            _ = pipeline.otherBoundary.finish()
        }
        let other = Task { try await WhisperKitOffMain.transcribe(pipeline, audioPath: "other.wav") }
        await fulfillment(of: [pipeline.otherBoundary.started], timeout: 1)
        let finished = expectation(description: "Owned decoder unwound")
        let timed = Task {
            await BoundedOperation.run(timeout: .milliseconds(100)) {
                defer { finished.fulfill() }
                return try await WhisperKitOffMain.transcribe(pipeline, audioPath: "unused.wav")
            }
        }
        await fulfillment(of: [pipeline.boundary.started], timeout: 1)
        let result = await timed.value
        XCTAssertNil(result)
        XCTAssertTrue(pipeline.boundary.isActive, "A deadline cannot preempt an in-flight native operation")
        XCTAssertEqual(pipeline.boundary.finish(), false, "The next supported callback must stop this request")
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertFalse(pipeline.boundary.isActive)
        XCTAssertTrue(pipeline.otherBoundary.isActive)
        XCTAssertEqual(pipeline.otherBoundary.finish(), true, "Another request on the same pipeline must stay enabled")
        _ = try await other.value
    }

    func testCancellationBeforeStartDoesNotInvokeDecoder() async throws {
        let pipeline = try await CallbackFilePipeline(WhisperKitConfig(load: false, download: false))
        defer { _ = pipeline.boundary.finish() }
        let task = Task { try await WhisperKitOffMain.transcribe(pipeline, audioPath: "unused.wav") }
        task.cancel()
        switch await task.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Cancelled file request must fail")
        }
        XCTAssertEqual(pipeline.boundary.calls, 0)
    }
}

private final class CallbackFilePipeline: WhisperKit {
    let boundary = FileDecoderBoundary()
    let otherBoundary = FileDecoderBoundary()

    override func transcribe(
        audioPath: String, audioInputOptions: AudioInputOptions? = nil,
        decodeOptions: DecodingOptions? = nil, callback: TranscriptionCallback? = nil
    ) async throws -> [TranscriptionResult] {
        let decoder = audioPath == "other.wav" ? otherBoundary : boundary
        await decoder.wait(callback: callback)
        return []
    }
}

/// Ignores Swift task cancellation and only returns at a decoder-supported boundary.
private final class FileDecoderBoundary: @unchecked Sendable {
    let started = XCTestExpectation(description: "Decoder started")
    private let lock = NSLock()
    private var callback: TranscriptionCallback?
    private var continuation: CheckedContinuation<Void, Never>?
    private var count = 0
    var isActive: Bool { lock.withLock { continuation != nil } }
    var calls: Int { lock.withLock { count } }

    func wait(callback: TranscriptionCallback?) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.callback = callback
                self.continuation = continuation
                count += 1
            }
            started.fulfill()
        }
    }

    func finish() -> Bool? {
        let state = lock.withLock {
            let pending = (callback, continuation)
            callback = nil
            continuation = nil
            return pending
        }
        let decision = state.0?(TranscriptionProgress(timings: TranscriptionTimings(), text: "", tokens: []))
        state.1?.resume()
        return decision
    }
}
