import XCTest

@testable import SpeakCore

// MARK: - OpenClawTypes Codable Tests

final class OpenClawTypesTests: XCTestCase {

    // MARK: - OpenClawConnectConfig

    func testOpenClawConnectConfig_codableRoundTrip() throws {
        let config = OpenClawConnectConfig(
            gatewayURL: "wss://gateway.example.com:4000",
            token: "secret-token",
            clientName: "test-client",
            sessionKey: "test:session"
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConnectConfig.self, from: encoded)

        XCTAssertEqual(decoded.gatewayURL, config.gatewayURL)
        XCTAssertEqual(decoded.token, config.token)
        XCTAssertEqual(decoded.clientName, config.clientName)
        XCTAssertEqual(decoded.sessionKey, config.sessionKey)
    }

    func testOpenClawConnectConfig_defaultValues() {
        let config = OpenClawConnectConfig(
            gatewayURL: "ws://localhost:3000",
            token: "tk"
        )

        XCTAssertEqual(config.clientName, "speak-ios")
        XCTAssertEqual(config.sessionKey, "speak-ios:voice")
    }

    // MARK: - OpenClawChatMessage

    func testOpenClawChatMessage_userRoleRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let message = OpenClawChatMessage(
            id: "msg-001",
            role: "user",
            content: "Hello from user",
            timestamp: date
        )

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: encoded)

        XCTAssertEqual(decoded.id, "msg-001")
        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "Hello from user")
        XCTAssertEqual(decoded.timestamp, date)
    }

    func testOpenClawChatMessage_assistantRoleRoundTrip() throws {
        let message = OpenClawChatMessage(
            id: "msg-002",
            role: "assistant",
            content: "Hello from assistant"
        )

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: encoded)

        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.content, "Hello from assistant")
    }

    func testOpenClawChatMessage_defaultIdIsUUID() {
        let msg1 = OpenClawChatMessage(role: "user", content: "a")
        let msg2 = OpenClawChatMessage(role: "user", content: "a")
        XCTAssertNotEqual(msg1.id, msg2.id, "Default IDs should be unique UUIDs")
    }

    func testOpenClawChatMessage_emptyContent_roundTrip() throws {
        let message = OpenClawChatMessage(id: "empty", role: "user", content: "")

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: encoded)

        XCTAssertEqual(decoded.content, "")
    }

    // MARK: - OpenClawConversation

    func testOpenClawConversation_emptyMessages_roundTrip() throws {
        let conv = OpenClawConversation(
            id: "conv-001",
            sessionKey: "speak-ios:voice",
            title: "Test Chat",
            messages: []
        )

        let encoded = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: encoded)

        XCTAssertEqual(decoded.id, "conv-001")
        XCTAssertEqual(decoded.sessionKey, "speak-ios:voice")
        XCTAssertEqual(decoded.title, "Test Chat")
        XCTAssertTrue(decoded.messages.isEmpty)
    }

    func testOpenClawConversation_withMessages_roundTrip() throws {
        let messages = [
            OpenClawChatMessage(id: "m1", role: "user", content: "Hi"),
            OpenClawChatMessage(id: "m2", role: "assistant", content: "Hello!"),
        ]
        let conv = OpenClawConversation(
            id: "conv-002",
            sessionKey: "s:k",
            title: "Chat",
            messages: messages
        )

        let encoded = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: encoded)

        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages[0].role, "user")
        XCTAssertEqual(decoded.messages[1].role, "assistant")
        XCTAssertEqual(decoded.messages[1].content, "Hello!")
    }

    func testOpenClawConversation_defaultTitle() {
        let conv = OpenClawConversation(sessionKey: "sk")
        XCTAssertEqual(conv.title, "New Conversation")
    }

    func testOpenClawConversation_defaultMessages_isEmpty() {
        let conv = OpenClawConversation(sessionKey: "sk")
        XCTAssertTrue(conv.messages.isEmpty)
    }
}

// MARK: - extractContent Tests

final class ExtractContentTests: XCTestCase {

    // MARK: - Missing or malformed message key

    func testExtractContent_noMessageKey_returnsEmpty() {
        let dict: [String: Any] = ["other": "value"]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    func testExtractContent_emptyDict_returnsEmpty() {
        XCTAssertEqual(OpenClawClient.extractContent(from: [:]), "")
    }

    func testExtractContent_messageNotADict_returnsEmpty() {
        let dict: [String: Any] = ["message": "not a dict"]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    // MARK: - String content

    func testExtractContent_stringContent_returnsString() {
        let dict: [String: Any] = [
            "message": ["content": "Hello, world!"] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "Hello, world!")
    }

    func testExtractContent_emptyStringContent_returnsEmpty() {
        let dict: [String: Any] = [
            "message": ["content": ""] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    func testExtractContent_stringContentWithUnicode_preserves() {
        let dict: [String: Any] = [
            "message": ["content": "こんにちは 🎙️"] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "こんにちは 🎙️")
    }

    // MARK: - Block array content

    func testExtractContent_singleTextBlock_returnsText() {
        let dict: [String: Any] = [
            "message": [
                "content": [["type": "text", "text": "Block text"]] as [[String: Any]],
            ] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "Block text")
    }

    func testExtractContent_multipleTextBlocks_concatenatesAll() {
        let dict: [String: Any] = [
            "message": [
                "content": [
                    ["type": "text", "text": "Hello "] as [String: Any],
                    ["type": "text", "text": "world"] as [String: Any],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "Hello world")
    }

    func testExtractContent_mixedBlockTypes_onlyTextConcatenated() {
        let dict: [String: Any] = [
            "message": [
                "content": [
                    ["type": "text", "text": "First"] as [String: Any],
                    ["type": "image", "url": "http://example.com/img.png"] as [String: Any],
                    ["type": "text", "text": " Last"] as [String: Any],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "First Last")
    }

    func testExtractContent_blocksMissingTextField_skipped() {
        let dict: [String: Any] = [
            "message": [
                "content": [
                    ["type": "text"] as [String: Any],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    func testExtractContent_emptyBlocksArray_returnsEmpty() {
        let dict: [String: Any] = [
            "message": [
                "content": [] as [[String: Any]],
            ] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    // MARK: - Missing content key

    func testExtractContent_messageWithNoContentKey_returnsEmpty() {
        let dict: [String: Any] = [
            "message": ["role": "assistant"] as [String: Any],
        ]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }
}
