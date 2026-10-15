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

    /// Cancels after a flushed 32 KiB body chunk has actually been written, covering the
    /// post-header streaming phase the tests above do not exercise.
    func testCancellation_AfterPartialBody_StopsTransportAndCompletesWithoutFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrouter-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = StubURLProtocol.makeSession()
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        let stopped = expectation(description: "Request cancelled after partial body")
        let completed = expectation(description: "Cancelled synthesis completes")
        // `stream()` flushes to disk every full 32 KiB, so a chunk exactly this size lets the
        // predicate below confirm the body-read loop actually ran, not just that the stub
        // handed headers to the loading system.
        let flushChunk = Data(repeating: 0x49, count: 32 * 1024)
        let response = HTTPURLResponse(
            url: URL(string: "https://stub.invalid")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "1000000"]
        )!
        StubURLProtocol.handler = { _ in .respondWithoutFinishing(response, flushChunk) }
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

        // Wait for the owned destination file to actually contain the flushed chunk: real
        // consumer progress through the body-read loop, before issuing the cancellation.
        let wroteFlushedChunk = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                    return false
                }
                return names.contains { name in
                    let path = directory.appendingPathComponent(name).path
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
                    return ((attrs[.size] as? Int) ?? 0) >= 32 * 1024
                }
            },
            object: nil
        )
        await fulfillment(of: [wroteFlushedChunk], timeout: 2)

        task.cancel()
        await fulfillment(of: [stopped, completed], timeout: 2)

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
