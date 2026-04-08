import XCTest

@testable import SpeakCore

final class LLMProtocolsTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - ChatMessage.Role

    func testChatMessageRole_rawValues() {
        XCTAssertEqual(ChatMessage.Role.system.rawValue, "system")
        XCTAssertEqual(ChatMessage.Role.user.rawValue, "user")
        XCTAssertEqual(ChatMessage.Role.assistant.rawValue, "assistant")
    }

    func testChatMessageRole_decodesFromString() throws {
        let json = "\"user\""
        let role = try decoder.decode(ChatMessage.Role.self, from: Data(json.utf8))
        XCTAssertEqual(role, .user)
    }

    func testChatMessageRole_codableRoundTrip() throws {
        for role in [ChatMessage.Role.system, .user, .assistant] {
            let data = try encoder.encode(role)
            let decoded = try decoder.decode(ChatMessage.Role.self, from: data)
            XCTAssertEqual(decoded, role)
        }
    }

    // MARK: - ChatMessage

    func testChatMessage_defaultID() {
        let msg = ChatMessage(role: .user, content: "Hello")
        XCTAssertNotNil(msg.id)
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.content, "Hello")
    }

    func testChatMessage_customID() {
        let id = UUID()
        let msg = ChatMessage(id: id, role: .assistant, content: "Response")
        XCTAssertEqual(msg.id, id)
    }

    func testChatMessage_codableRoundTrip() throws {
        let id = UUID()
        let original = ChatMessage(id: id, role: .system, content: "You are helpful.")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.role, .system)
        XCTAssertEqual(decoded.content, "You are helpful.")
    }

    func testChatMessage_allRolesCodable() throws {
        for role in [ChatMessage.Role.system, .user, .assistant] {
            let msg = ChatMessage(role: role, content: "test")
            let data = try encoder.encode(msg)
            let decoded = try decoder.decode(ChatMessage.self, from: data)
            XCTAssertEqual(decoded.role, role)
        }
    }

    func testChatMessage_hashable() {
        let id = UUID()
        let a = ChatMessage(id: id, role: .user, content: "Hi")
        let b = ChatMessage(id: id, role: .user, content: "Hi")
        XCTAssertEqual(a, b)
        var set = Set<ChatMessage>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - ChatCostBreakdown

    func testChatCostBreakdown_codableRoundTrip() throws {
        let original = ChatCostBreakdown(
            inputTokens: 100,
            outputTokens: 200,
            totalCost: Decimal(string: "0.0150")!,
            currency: "USD"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChatCostBreakdown.self, from: data)
        XCTAssertEqual(decoded.inputTokens, 100)
        XCTAssertEqual(decoded.outputTokens, 200)
        XCTAssertEqual(decoded.totalCost, original.totalCost)
        XCTAssertEqual(decoded.currency, "USD")
    }

    func testChatCostBreakdown_zeroCost() throws {
        let cost = ChatCostBreakdown(inputTokens: 0, outputTokens: 0, totalCost: 0, currency: "USD")
        let data = try encoder.encode(cost)
        let decoded = try decoder.decode(ChatCostBreakdown.self, from: data)
        XCTAssertEqual(decoded.totalCost, 0)
    }

    func testChatCostBreakdown_hashable() {
        let a = ChatCostBreakdown(inputTokens: 10, outputTokens: 20, totalCost: 1, currency: "USD")
        let b = ChatCostBreakdown(inputTokens: 10, outputTokens: 20, totalCost: 1, currency: "USD")
        XCTAssertEqual(a, b)
    }

    // MARK: - ChatResponse

    func testChatResponse_withCostAndPayload() throws {
        let msg = ChatMessage(role: .assistant, content: "Answer")
        let cost = ChatCostBreakdown(inputTokens: 50, outputTokens: 100, totalCost: 0.005, currency: "USD")
        let original = ChatResponse(
            messages: [msg],
            finishReason: "stop",
            cost: cost,
            rawPayload: "{\"id\":\"resp-1\"}"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChatResponse.self, from: data)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages[0].content, "Answer")
        XCTAssertEqual(decoded.finishReason, "stop")
        XCTAssertNotNil(decoded.cost)
        XCTAssertEqual(decoded.rawPayload, "{\"id\":\"resp-1\"}")
    }

    func testChatResponse_noCostNoPayload() throws {
        let original = ChatResponse(messages: [], finishReason: "length", cost: nil, rawPayload: nil)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChatResponse.self, from: data)
        XCTAssertTrue(decoded.messages.isEmpty)
        XCTAssertEqual(decoded.finishReason, "length")
        XCTAssertNil(decoded.cost)
        XCTAssertNil(decoded.rawPayload)
    }

    func testChatResponse_multipleMessages() throws {
        let msgs = [
            ChatMessage(role: .system, content: "You are helpful."),
            ChatMessage(role: .user, content: "What is 2+2?"),
            ChatMessage(role: .assistant, content: "4"),
        ]
        let original = ChatResponse(messages: msgs, finishReason: "stop", cost: nil, rawPayload: nil)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChatResponse.self, from: data)
        XCTAssertEqual(decoded.messages.count, 3)
        XCTAssertEqual(decoded.messages[2].content, "4")
    }

    func testChatResponse_hashable() {
        let msg = ChatMessage(role: .user, content: "hi")
        let a = ChatResponse(messages: [msg], finishReason: "stop", cost: nil, rawPayload: nil)
        let b = ChatResponse(messages: [msg], finishReason: "stop", cost: nil, rawPayload: nil)
        XCTAssertEqual(a, b)
    }
}
