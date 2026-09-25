import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class OpenRouterReviewRegressionTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testStrictInlineFormatsRejectUnknownContainersBeforeReadingOrSending() async throws {
        let client = OpenRouterInlineAudioTranscriptionClient(
            apiKey: "test", session: StubURLProtocol.makeSession(), formatPolicy: .supportedFormatsOnly
        )
        for ext in ["webm", "opus", "unknown", ""] {
            // An absent source also proves format validation precedes disk access.
            let audio = URL(fileURLWithPath: "/absent/audio").appendingPathExtension(ext)
            do {
                _ = try await client.transcribeFile(at: audio, model: "vendor/chat", language: nil)
                XCTFail("Expected unsupported format")
            } catch {
                XCTAssertEqual(error as? OpenRouterInlineAudioTranscriptionClient.InputError, .unsupportedFormat)
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testBoundedReadRefusesGrowthAndAcceptsExactLimitWithoutIntegerTraps() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 1, count: 13).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for limit: Int64 in [4, .min] {
            try handle.seek(toOffset: 0)
            do {
                _ = try OpenRouterInlineAudioTranscriptionClient.readAudio(from: handle, limit: limit)
                XCTFail("Expected bounded read to fail")
            } catch OpenRouterClientError.audioFileTooLarge(let size, let reportedLimit) {
                XCTAssertEqual(reportedLimit, limit)
                XCTAssertEqual(size, limit == 4 ? 5 : 0)
            }
        }
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try OpenRouterInlineAudioTranscriptionClient.readAudio(from: handle, limit: 13).count, 13)
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try OpenRouterInlineAudioTranscriptionClient.readAudio(from: handle, limit: .max).count, 13)
    }

    func testCancellationDuringDurationEnrichmentRejectsLateServerSuccess() async throws {
        let entered = expectation(description: "Duration started after provider success")
        let gate = OpenRouterDurationGate(entered: entered)
        StubURLProtocol.handler = { request in
            .ok(Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8), url: request.url!)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2]).write(to: url)
        let client = OpenRouterInlineAudioTranscriptionClient(
            apiKey: "test", session: StubURLProtocol.makeSession(), durationResolver: { _ in await gate.wait() }
        )
        let task = Task { try await client.transcribeFile(at: url, model: "vendor/chat", language: nil) }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation must survive duration enrichment")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testDelegateTransportRejectsHeadersAndChunksBeforeTheBodyFinishes() async throws {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        for declared in [true, false] {
            let stopped = expectation(description: "Over-limit delegate request stops")
            StubURLProtocol.onStopLoading = { stopped.fulfill() }
            StubURLProtocol.handler = { request in
                var headers = ["Content-Type": "application/json"]
                if declared { headers["Content-Length"] = "9" }
                return .respondWithoutFinishing(
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!,
                    declared ? Data() : Data(repeating: 1, count: 9)
                )
            }
            do {
                _ = try await OpenRouterBoundedResponseTransport.perform(
                    URLRequest(url: URL(string: "https://stub.invalid/bounded")!), session: session,
                    limit: 8, deadline: .seconds(5), engine: .delegate
                )
                XCTFail("Expected delegate limit rejection")
            } catch { XCTAssertEqual(error as? OpenRouterBoundedResponseTransport.Failure, .responseTooLarge) }
            await fulfillment(of: [stopped], timeout: 5)
        }
    }

    func testDelegateDeadlineCancelsANeverFinishingResponse() async throws {
        let stopped = expectation(description: "Deadline stops delegate request")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await OpenRouterBoundedResponseTransport.perform(
                URLRequest(url: URL(string: "https://stub.invalid/bounded")!), session: session,
                limit: 8, deadline: .milliseconds(200), engine: .delegate
            )
            XCTFail("Expected delegate deadline")
        } catch { XCTAssertEqual(error as? OpenRouterBoundedResponseTransport.Failure, .timedOut) }
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testBothEnginesCancelHangingRequestsAndAppleReusesTheSuppliedSession() async throws {
        for engine in [OpenRouterBoundedResponseTransport.Engine.platformDefault, .delegate] {
            let session = StubURLProtocol.makeSession()
            defer { session.invalidateAndCancel() }
            let started = expectation(description: "Request started")
            let stopped = expectation(description: "Request stopped")
            StubURLProtocol.onStartLoading = { started.fulfill() }
            StubURLProtocol.onStopLoading = { stopped.fulfill() }
            StubURLProtocol.handler = { _ in .hang }
            let task = Task {
                try await OpenRouterBoundedResponseTransport.perform(
                    URLRequest(url: URL(string: "https://stub.invalid/bounded")!), session: session,
                    limit: 8, deadline: .seconds(30), engine: engine
                )
            }
            await fulfillment(of: [started], timeout: 5)
            #if canImport(Darwin)
            let tasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            if case .platformDefault = engine { XCTAssertEqual(tasks.count, 1) }
            #endif
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)")
            }
            await fulfillment(of: [stopped], timeout: 5)
        }
    }
}

private actor OpenRouterDurationGate {
    let entered: XCTestExpectation
    var continuation: CheckedContinuation<TimeInterval, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async -> TimeInterval {
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func release() { continuation?.resume(returning: 3); continuation = nil }
}
