import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakCore

final class OpenRouterSpeechCancellationTests: XCTestCase {
    func testCancellation_BeforeTaskCreation_CancelsTheCreatedTask() async {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let policy = OpenRouterAudioRedirectPolicy()
        policy.cancel()
        let completed = expectation(description: "Created task cancelled")
        let task = session.dataTask(with: URL(string: "https://stub.invalid")!) { _, _, error in
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
            completed.fulfill()
        }

        policy.urlSession(session, didCreateTask: task)
        task.resume()

        await fulfillment(of: [completed], timeout: 2)
    }

    func testTaskDelegate_RegistersTransportBeforeResponseHeaders() async {
        let session = StubURLProtocol.makeSession()
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        let started = expectation(description: "Transport waiting for headers")
        let stopped = expectation(description: "Delegate cancels registered transport")
        let completed = expectation(description: "Transport cancellation completes")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let policy = OpenRouterAudioRedirectPolicy()
        let task = Task {
            defer { completed.fulfill() }
            do {
                _ = try await session.bytes(
                    for: URLRequest(url: URL(string: "https://stub.invalid")!), delegate: policy
                )
                XCTFail("Expected transport cancellation")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cancelled)
            }
        }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)

        // Do not cancel the Swift task: prove the per-request delegate owns the pending URLSession task.
        policy.cancel()

        await fulfillment(of: [stopped, completed], timeout: 2)
    }

    func testCancellation_WhileAwaitingHeaders_StopsTransportAndCompletesWithoutFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrouter-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = StubURLProtocol.makeSession()
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        let started = expectation(description: "Request waiting for headers")
        let stopped = expectation(description: "Request cancelled before headers")
        let completed = expectation(description: "Cancelled synthesis completes")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let client = OpenRouterAudioClient(
            apiKeyProvider: { "test-key" }, session: session, temporaryDirectory: directory
        )
        let task = Task {
            defer { completed.fulfill() }
            do {
                _ = try await client.synthesize(text: "Hello", model: "provider/tts", voice: nil)
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
            }
        }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()
        await fulfillment(of: [stopped, completed], timeout: 2)

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
