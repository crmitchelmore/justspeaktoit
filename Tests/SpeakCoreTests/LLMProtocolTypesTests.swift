import XCTest

@testable import SpeakCore

final class LLMProtocolTypesTests: XCTestCase {

    // MARK: - ChatMessage.Role raw values
    // These raw values are part of the API contract with LLM providers.

    func testChatMessageRole_rawValues_matchAPIContract() {
        XCTAssertEqual(ChatMessage.Role.system.rawValue, "system")
        XCTAssertEqual(ChatMessage.Role.user.rawValue, "user")
        XCTAssertEqual(ChatMessage.Role.assistant.rawValue, "assistant")
    }

    func testChatMessageRole_codableRoundTrip() throws {
        for role in [ChatMessage.Role.system, .user, .assistant] {
            let encoded = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(ChatMessage.Role.self, from: encoded)
            XCTAssertEqual(decoded, role)
        }
    }

    // MARK: - ChatMessage

    func testChatMessage_defaultIDIsUnique() {
        let m1 = ChatMessage(role: .user, content: "Hello")
        let m2 = ChatMessage(role: .user, content: "Hello")
        XCTAssertNotEqual(m1.id, m2.id)
    }

    func testChatMessage_hashableConformance() {
        let msg = ChatMessage(role: .assistant, content: "Hi")
        var set = Set<ChatMessage>()
        set.insert(msg)
        set.insert(msg)
        XCTAssertEqual(set.count, 1)
    }

    func testChatMessage_codableRoundTrip() throws {
        let original = ChatMessage(role: .system, content: "Be concise.")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, .system)
        XCTAssertEqual(decoded.content, "Be concise.")
    }

    // MARK: - ChatCostBreakdown

    func testChatCostBreakdown_storedCorrectly() {
        let cost = ChatCostBreakdown(
            inputTokens: 500, outputTokens: 250, totalCost: Decimal(string: "0.0015")!, currency: "USD"
        )
        XCTAssertEqual(cost.inputTokens, 500)
        XCTAssertEqual(cost.outputTokens, 250)
        XCTAssertEqual(cost.totalCost, Decimal(string: "0.0015"))
        XCTAssertEqual(cost.currency, "USD")
    }

    func testChatCostBreakdown_hashableConformance() {
        let cost = ChatCostBreakdown(inputTokens: 10, outputTokens: 5, totalCost: 0.001, currency: "USD")
        var set = Set<ChatCostBreakdown>()
        set.insert(cost)
        set.insert(cost)
        XCTAssertEqual(set.count, 1)
    }

    func testChatCostBreakdown_codableRoundTrip() throws {
        let original = ChatCostBreakdown(
            inputTokens: 100, outputTokens: 50, totalCost: Decimal(string: "0.002")!, currency: "EUR"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatCostBreakdown.self, from: data)
        XCTAssertEqual(decoded.inputTokens, original.inputTokens)
        XCTAssertEqual(decoded.outputTokens, original.outputTokens)
        XCTAssertEqual(decoded.totalCost, original.totalCost)
        XCTAssertEqual(decoded.currency, "EUR")
    }

    // MARK: - ChatResponse

    func testChatResponse_withNilOptionals_codableRoundTrip() throws {
        let msg = ChatMessage(role: .assistant, content: "Done")
        let original = ChatResponse(
            messages: [msg], finishReason: "stop", cost: nil, rawPayload: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        XCTAssertEqual(decoded.finishReason, "stop")
        XCTAssertNil(decoded.cost)
        XCTAssertNil(decoded.rawPayload)
        XCTAssertEqual(decoded.messages.count, 1)
    }

    func testChatResponse_withAllFields_codableRoundTrip() throws {
        let cost = ChatCostBreakdown(inputTokens: 10, outputTokens: 5, totalCost: 0.01, currency: "USD")
        let original = ChatResponse(
            messages: [ChatMessage(role: .user, content: "Hi")],
            finishReason: "length",
            cost: cost,
            rawPayload: "{\"model\":\"gpt-4\"}"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        XCTAssertEqual(decoded.finishReason, "length")
        XCTAssertNotNil(decoded.cost)
        XCTAssertEqual(decoded.rawPayload, "{\"model\":\"gpt-4\"}")
    }

    // MARK: - LiveTranscriptionUpdate

    func testLiveTranscriptionUpdate_defaultIsFinal_isFalse() {
        let update = LiveTranscriptionUpdate(text: "partial")
        XCTAssertFalse(update.isFinal)
        XCTAssertNil(update.confidence)
    }

    func testLiveTranscriptionUpdate_finalWithConfidence() {
        let update = LiveTranscriptionUpdate(text: "done", isFinal: true, confidence: 0.92)
        XCTAssertTrue(update.isFinal)
        XCTAssertEqual(update.confidence, 0.92)
    }
}
