import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class OpenRouterChatDelegationTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAppleOneShotClientUsesSharedRemoteContract() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Custom Apple app")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertEqual(body["max_tokens"] as? Int, 99)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.first, ["role": "system", "content": "Keep prompt."])
            return .ok(Data(#"{"choices":[{"message":{"content":"Shared result"},"finish_reason":"stop"}]}"#.utf8))
        }
        let client = OpenRouterAPIClient(
            apiKeyProvider: { "key" }, session: StubURLProtocol.makeSession(),
            branding: .init(title: "Custom Apple app", referer: "https://test.invalid")
        )
        let result = try await client.sendChat(
            systemPrompt: "Keep prompt.", messages: [.init(role: .user, content: "raw")],
            model: "test/model", temperature: 0.2, maxTokens: 99
        )
        XCTAssertEqual(result.messages.map(\.content), ["Keep prompt.", "raw", "Shared result"])
        XCTAssertEqual(result.finishReason, "stop")
    }

    func testAppleLegacyNoKeyFallbackRemainsSeparateFromRemoteTransport() async throws {
        let client = OpenRouterAPIClient(apiKeyProvider: { nil }, session: StubURLProtocol.makeSession())
        let result = try await client.sendChat(
            systemPrompt: nil, messages: [.init(role: .user, content: "hello world")],
            model: "test/model", temperature: 0.2
        )
        XCTAssertEqual(result.finishReason, "fallback-local")
        XCTAssertFalse(result.messages.last?.content.isEmpty ?? true)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }
}
