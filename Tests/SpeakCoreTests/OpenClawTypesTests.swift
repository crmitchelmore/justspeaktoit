import XCTest

@testable import SpeakCore

// MARK: - OpenClawTypesTests

final class OpenClawTypesTests: XCTestCase {

    // MARK: - OpenClawChatMessage Codable

    func testChatMessage_roundTrip_preservesAllFields() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OpenClawChatMessage(
            id: "msg-001",
            role: "user",
            content: "Hello, assistant",
            timestamp: fixedDate
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, "msg-001")
        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "Hello, assistant")
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, fixedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testChatMessage_roleAssistant_roundTrip() throws {
        let original = OpenClawChatMessage(id: "a1", role: "assistant", content: "Hi there")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.content, "Hi there")
    }

    func testChatMessage_emptyContent_roundTrip() throws {
        let original = OpenClawChatMessage(id: "empty", role: "user", content: "")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        XCTAssertEqual(decoded.content, "")
    }

    func testChatMessage_defaultId_isNonEmpty() {
        let message = OpenClawChatMessage(role: "user", content: "test")
        XCTAssertFalse(message.id.isEmpty, "Default id should be a non-empty UUID string")
    }

    // MARK: - OpenClawConversation Codable

    func testConversation_roundTrip_noMessages() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OpenClawConversation(
            id: "conv-001",
            sessionKey: "session:test",
            title: "Test Chat",
            messages: [],
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: data)

        XCTAssertEqual(decoded.id, "conv-001")
        XCTAssertEqual(decoded.sessionKey, "session:test")
        XCTAssertEqual(decoded.title, "Test Chat")
        XCTAssertTrue(decoded.messages.isEmpty)
    }

    func testConversation_roundTrip_withMessages() throws {
        let msg = OpenClawChatMessage(id: "m1", role: "user", content: "ping")
        let conv = OpenClawConversation(
            id: "c1",
            sessionKey: "sk",
            title: "Chat",
            messages: [msg]
        )
        let data = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: data)

        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages[0].id, "m1")
        XCTAssertEqual(decoded.messages[0].content, "ping")
    }

    func testConversation_defaultTitle_isNewConversation() {
        let conv = OpenClawConversation(sessionKey: "sk")
        XCTAssertEqual(conv.title, "New Conversation")
    }

    func testConversation_defaultMessages_isEmpty() {
        let conv = OpenClawConversation(sessionKey: "sk")
        XCTAssertTrue(conv.messages.isEmpty)
    }
}

// MARK: - OpenClawExtractContentTests

final class OpenClawExtractContentTests: XCTestCase {

    // MARK: - Missing / malformed message key

    func testExtractContent_missingMessageKey_returnsEmpty() {
        let result = OpenClawClient.extractContent(from: [:])
        XCTAssertEqual(result, "")
    }

    func testExtractContent_messageIsNotDict_returnsEmpty() {
        let dict: [String: Any] = ["message": "not a dict"]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "")
    }

    // MARK: - Plain string content

    func testExtractContent_plainStringContent_returnsString() {
        let dict: [String: Any] = ["message": ["content": "Hello world"]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "Hello world")
    }

    func testExtractContent_plainStringContent_emptyString() {
        let dict: [String: Any] = ["message": ["content": ""]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "")
    }

    // MARK: - Structured block content

    func testExtractContent_singleTextBlock_returnsText() {
        let blocks: [[String: Any]] = [["type": "text", "text": "Block one"]]
        let dict: [String: Any] = ["message": ["content": blocks]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "Block one")
    }

    func testExtractContent_multipleTextBlocks_joinsAll() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "Hello "],
            ["type": "text", "text": "world"],
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "Hello world")
    }

    func testExtractContent_nonTextBlocksFiltered() {
        let blocks: [[String: Any]] = [
            ["type": "image", "url": "http://example.com/img.png"],
            ["type": "text", "text": "caption"],
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "caption", "Non-text blocks should be filtered out")
    }

    func testExtractContent_allNonTextBlocks_returnsEmpty() {
        let blocks: [[String: Any]] = [
            ["type": "image", "url": "http://example.com/img.png"],
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "")
    }

    func testExtractContent_emptyBlocksArray_returnsEmpty() {
        let blocks: [[String: Any]] = []
        let dict: [String: Any] = ["message": ["content": blocks]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "")
    }

    func testExtractContent_textBlockMissingTextField_skipped() {
        // A "text" block that lacks the "text" key should not contribute to output
        let blocks: [[String: Any]] = [
            ["type": "text"],
            ["type": "text", "text": "present"],
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "present")
    }

    func testExtractContent_missingContentKey_returnsEmpty() {
        let dict: [String: Any] = ["message": ["other_key": "value"]]
        let result = OpenClawClient.extractContent(from: dict)
        XCTAssertEqual(result, "")
    }
}
