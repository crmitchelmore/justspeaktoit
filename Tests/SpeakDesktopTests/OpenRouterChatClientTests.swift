import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest

final class OpenRouterChatClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testRequestAndResponsePreserveSharedChatContract() async throws {
        let systemPrompt = "  Keep this exact system prompt.\n"
        let userMessage = ChatMessage(role: .user, content: "hello")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Test app")
            XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://test.invalid")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://test.invalid")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertEqual(body["model"] as? String, "test/model")
            XCTAssertEqual(body["temperature"] as? Double, 0.2)
            XCTAssertEqual(body["max_tokens"] as? Int, 128)
            XCTAssertNil(body["stream"])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage.content]
            ])
            return .ok(Data(Self.response.utf8), url: request.url!)
        }
        let client = OpenRouterChatClient(
            apiKey: " \ntest-key\t", session: StubURLProtocol.makeSession(),
            branding: .init(title: "Test app", referer: "https://test.invalid")
        )
        let result = try await client.sendChat(
            systemPrompt: systemPrompt, messages: [userMessage], model: "test/model",
            temperature: 0.2, maxTokens: 128
        )
        XCTAssertEqual(result.messages.map(\.role), [.system, .user, .assistant])
        XCTAssertEqual(result.messages[0].content, systemPrompt)
        XCTAssertEqual(result.messages[1].id, userMessage.id)
        XCTAssertEqual(result.messages.last?.content, "Hello.")
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.cost?.inputTokens, 10)
        XCTAssertEqual(result.cost?.outputTokens, 2)
        XCTAssertEqual(result.cost?.totalCost, Decimal(12) / 1_000_000)
        XCTAssertEqual(result.rawPayload, Self.response)
    }

    func testMissingCredentialsNeverPerformARequestOrMockSuccess() async throws {
        do {
            _ = try await send(apiKey: " \n\t")
            XCTFail("Expected missing credentials")
        } catch OpenRouterClientError.apiKeyMissing {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testHTTPFailurePreservesStatusAndBody() async throws {
        StubURLProtocol.handler = { _ in .status(429, Data("Try later".utf8)) }
        do {
            _ = try await send()
            XCTFail("Expected HTTP failure")
        } catch OpenRouterClientError.httpStatus(let status, let body) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(body, "Try later")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNonHTTPAndMalformedResponsesFail() async throws {
        StubURLProtocol.handler = { request in
            .respond(
                URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data()
            )
        }
        do {
            _ = try await send()
            XCTFail("Expected invalid response")
        } catch OpenRouterClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        StubURLProtocol.handler = { _ in .ok(Data("not JSON".utf8)) }
        do {
            _ = try await send()
            XCTFail("Expected decoding failure")
        } catch { XCTAssertTrue(error is DecodingError, "\(error)") }
    }

    func testCancellationStopsAnInFlightRequest() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request stopped")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let task = Task { try await self.send() }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testPreCancelledTaskNeverStartsARequest() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.send()
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    private func send(apiKey: String = "test-key") async throws -> ChatResponse {
        try await OpenRouterChatClient(apiKey: apiKey, session: StubURLProtocol.makeSession()).sendChat(
            systemPrompt: nil, messages: [.init(role: .user, content: "hello")],
            model: "test/model", temperature: 0.2
        )
    }

    private static let response = #"""
    {"choices":[{"index":0,"message":{"role":"assistant","content":"Hello."},"finish_reason":"stop"}],
     "usage":{"prompt_tokens":10,"completion_tokens":2}}
    """#
}
