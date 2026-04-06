import XCTest

@testable import SpeakCore

final class LLMProtocolsTests: XCTestCase {

    // MARK: - ChatMessage.Role

    func testRole_rawValues_areExpectedStrings() {
        XCTAssertEqual(ChatMessage.Role.system.rawValue, "system")
        XCTAssertEqual(ChatMessage.Role.user.rawValue, "user")
        XCTAssertEqual(ChatMessage.Role.assistant.rawValue, "assistant")
    }

    func testRole_codable_roundTrip() throws {
        for role in [ChatMessage.Role.system, .user, .assistant] {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(ChatMessage.Role.self, from: data)
            XCTAssertEqual(decoded, role)
        }
    }

    // MARK: - ChatMessage construction

    func testChatMessage_defaultID_isUnique() {
        let m1 = ChatMessage(role: .user, content: "A")
        let m2 = ChatMessage(role: .user, content: "B")
        XCTAssertNotEqual(m1.id, m2.id)
    }

    func testChatMessage_explicitID_preserved() {
        let fixedID = UUID()
        let msg = ChatMessage(id: fixedID, role: .assistant, content: "Hello")
        XCTAssertEqual(msg.id, fixedID)
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "Hello")
    }

    // MARK: - ChatMessage Codable round-trip

    func testChatMessage_codableRoundTrip_userMessage() throws {
        let original = ChatMessage(role: .user, content: "What is 2 + 2?")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.content, "What is 2 + 2?")
    }

    func testChatMessage_codableRoundTrip_systemMessage() throws {
        let original = ChatMessage(role: .system, content: "You are a helpful assistant.")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.role, .system)
        XCTAssertEqual(decoded.content, "You are a helpful assistant.")
    }

    func testChatMessage_codableRoundTrip_assistantMessage() throws {
        let original = ChatMessage(role: .assistant, content: "4")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.content, "4")
    }

    // MARK: - ChatMessage Hashable

    func testChatMessage_hashable_sameInstanceInSet() {
        let msg = ChatMessage(role: .user, content: "Hello")
        var set = Set<ChatMessage>()
        set.insert(msg)
        set.insert(msg)
        XCTAssertEqual(set.count, 1)
    }

    func testChatMessage_hashable_differentIDsDifferentHash() {
        let m1 = ChatMessage(role: .user, content: "Same content")
        let m2 = ChatMessage(role: .user, content: "Same content")
        // Different UUIDs → different identities
        XCTAssertNotEqual(m1, m2)
        var set = Set<ChatMessage>()
        set.insert(m1)
        set.insert(m2)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - ChatCostBreakdown construction

    func testCostBreakdown_construction_preservesFields() {
        let cost = ChatCostBreakdown(
            inputTokens: 500,
            outputTokens: 250,
            totalCost: Decimal(string: "0.0035")!,
            currency: "USD"
        )
        XCTAssertEqual(cost.inputTokens, 500)
        XCTAssertEqual(cost.outputTokens, 250)
        XCTAssertEqual(cost.totalCost, Decimal(string: "0.0035")!)
        XCTAssertEqual(cost.currency, "USD")
    }

    // MARK: - ChatCostBreakdown Codable round-trip

    func testCostBreakdown_codableRoundTrip_nonZeroCost() throws {
        let original = ChatCostBreakdown(
            inputTokens: 1000,
            outputTokens: 500,
            totalCost: Decimal(string: "0.015")!,
            currency: "USD"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatCostBreakdown.self, from: data)

        XCTAssertEqual(decoded.inputTokens, original.inputTokens)
        XCTAssertEqual(decoded.outputTokens, original.outputTokens)
        XCTAssertEqual(decoded.totalCost, original.totalCost)
        XCTAssertEqual(decoded.currency, original.currency)
    }

    func testCostBreakdown_codableRoundTrip_zeroCost() throws {
        let original = ChatCostBreakdown(
            inputTokens: 0,
            outputTokens: 0,
            totalCost: 0,
            currency: "USD"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatCostBreakdown.self, from: data)

        XCTAssertEqual(decoded.inputTokens, 0)
        XCTAssertEqual(decoded.outputTokens, 0)
        XCTAssertEqual(decoded.totalCost, 0)
    }

    func testCostBreakdown_codableRoundTrip_nonUSDCurrency() throws {
        let original = ChatCostBreakdown(
            inputTokens: 100,
            outputTokens: 50,
            totalCost: Decimal(string: "0.005")!,
            currency: "EUR"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatCostBreakdown.self, from: data)

        XCTAssertEqual(decoded.currency, "EUR")
    }

    // MARK: - ChatCostBreakdown Hashable

    func testCostBreakdown_hashable_equalValuesAreEqual() {
        let c1 = ChatCostBreakdown(inputTokens: 100, outputTokens: 50, totalCost: 0.01, currency: "USD")
        let c2 = ChatCostBreakdown(inputTokens: 100, outputTokens: 50, totalCost: 0.01, currency: "USD")
        XCTAssertEqual(c1, c2)
        var set = Set<ChatCostBreakdown>()
        set.insert(c1)
        set.insert(c2)
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - ChatResponse construction

    func testChatResponse_withOptionalNils_construction() {
        let response = ChatResponse(
            messages: [],
            finishReason: "stop",
            cost: nil,
            rawPayload: nil
        )
        XCTAssertTrue(response.messages.isEmpty)
        XCTAssertEqual(response.finishReason, "stop")
        XCTAssertNil(response.cost)
        XCTAssertNil(response.rawPayload)
    }

    func testChatResponse_withAllFields_construction() {
        let msg = ChatMessage(role: .assistant, content: "42")
        let cost = ChatCostBreakdown(inputTokens: 10, outputTokens: 5, totalCost: 0.001, currency: "USD")
        let response = ChatResponse(
            messages: [msg],
            finishReason: "stop",
            cost: cost,
            rawPayload: "{\"choices\":[]}"
        )
        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.finishReason, "stop")
        XCTAssertNotNil(response.cost)
        XCTAssertEqual(response.rawPayload, "{\"choices\":[]}")
    }

    // MARK: - ChatResponse Codable round-trip

    func testChatResponse_codableRoundTrip_withCost() throws {
        let msg = ChatMessage(role: .assistant, content: "Hello!")
        let cost = ChatCostBreakdown(inputTokens: 50, outputTokens: 20, totalCost: 0.002, currency: "USD")
        let original = ChatResponse(
            messages: [msg],
            finishReason: "stop",
            cost: cost,
            rawPayload: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)

        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages.first?.content, "Hello!")
        XCTAssertEqual(decoded.finishReason, "stop")
        XCTAssertNotNil(decoded.cost)
        XCTAssertEqual(decoded.cost?.totalCost, Decimal(string: "0.002")!)
    }

    func testChatResponse_codableRoundTrip_withoutCost() throws {
        let msg = ChatMessage(role: .user, content: "Ping")
        let original = ChatResponse(
            messages: [msg],
            finishReason: "length",
            cost: nil,
            rawPayload: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)

        XCTAssertNil(decoded.cost)
        XCTAssertEqual(decoded.finishReason, "length")
    }

    func testChatResponse_codableRoundTrip_multipleMessages() throws {
        let messages = [
            ChatMessage(role: .system, content: "Be helpful."),
            ChatMessage(role: .user, content: "Hello?"),
            ChatMessage(role: .assistant, content: "Hi!"),
        ]
        let original = ChatResponse(
            messages: messages,
            finishReason: "stop",
            cost: nil,
            rawPayload: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)

        XCTAssertEqual(decoded.messages.count, 3)
        XCTAssertEqual(decoded.messages[0].role, .system)
        XCTAssertEqual(decoded.messages[1].role, .user)
        XCTAssertEqual(decoded.messages[2].role, .assistant)
    }

    func testChatResponse_codableRoundTrip_withRawPayload() throws {
        let payload = "{\"id\":\"resp-123\",\"model\":\"gpt-4\"}"
        let original = ChatResponse(
            messages: [],
            finishReason: "stop",
            cost: nil,
            rawPayload: payload
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)

        XCTAssertEqual(decoded.rawPayload, payload)
    }

    // MARK: - ChatResponse Hashable

    func testChatResponse_hashable_equalValuesAreEqual() {
        let fixedID = UUID()
        let msg = ChatMessage(id: fixedID, role: .user, content: "Hello")
        let cost = ChatCostBreakdown(inputTokens: 10, outputTokens: 5, totalCost: 0.001, currency: "USD")
        let r1 = ChatResponse(messages: [msg], finishReason: "stop", cost: cost, rawPayload: nil)
        let r2 = ChatResponse(messages: [msg], finishReason: "stop", cost: cost, rawPayload: nil)
        XCTAssertEqual(r1, r2)
    }
}
