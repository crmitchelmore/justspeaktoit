import XCTest

@testable import SpeakCore

final class OpenClawTypesTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - OpenClawConnectConfig

    func testOpenClawConnectConfig_defaultInitializer() {
        let config = OpenClawConnectConfig(
            gatewayURL: "ws://localhost:8080",
            token: "secret-token"
        )
        XCTAssertEqual(config.gatewayURL, "ws://localhost:8080")
        XCTAssertEqual(config.token, "secret-token")
        XCTAssertEqual(config.clientName, "speak-ios")
        XCTAssertEqual(config.sessionKey, "speak-ios:voice")
    }

    func testOpenClawConnectConfig_customInitializer() {
        let config = OpenClawConnectConfig(
            gatewayURL: "wss://example.com:443",
            token: "tok",
            clientName: "speak-mac",
            sessionKey: "speak-mac:voice"
        )
        XCTAssertEqual(config.clientName, "speak-mac")
        XCTAssertEqual(config.sessionKey, "speak-mac:voice")
    }

    func testOpenClawConnectConfig_codableRoundTrip() throws {
        let original = OpenClawConnectConfig(
            gatewayURL: "wss://gateway.example.com",
            token: "abc123",
            clientName: "speak-ios",
            sessionKey: "speak-ios:voice"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OpenClawConnectConfig.self, from: data)
        XCTAssertEqual(decoded.gatewayURL, original.gatewayURL)
        XCTAssertEqual(decoded.token, original.token)
        XCTAssertEqual(decoded.clientName, original.clientName)
        XCTAssertEqual(decoded.sessionKey, original.sessionKey)
    }

    func testOpenClawConnectConfig_decodesFromJSON() throws {
        let json = """
        {"gatewayURL":"ws://localhost:9090","token":"tok","clientName":"test-client","sessionKey":"test:key"}
        """
        let config = try decoder.decode(OpenClawConnectConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.gatewayURL, "ws://localhost:9090")
        XCTAssertEqual(config.token, "tok")
        XCTAssertEqual(config.clientName, "test-client")
        XCTAssertEqual(config.sessionKey, "test:key")
    }

    func testOpenClawConnectConfig_isMutable() {
        var config = OpenClawConnectConfig(gatewayURL: "ws://old", token: "old-token")
        config.gatewayURL = "wss://new"
        config.token = "new-token"
        XCTAssertEqual(config.gatewayURL, "wss://new")
        XCTAssertEqual(config.token, "new-token")
    }

    // MARK: - OpenClawChatMessage

    func testOpenClawChatMessage_defaultInitializer() {
        let msg = OpenClawChatMessage(role: "user", content: "Hello")
        XCTAssertFalse(msg.id.isEmpty)
        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "Hello")
    }

    func testOpenClawChatMessage_customID() {
        let msg = OpenClawChatMessage(id: "fixed-id", role: "assistant", content: "Hi")
        XCTAssertEqual(msg.id, "fixed-id")
    }

    func testOpenClawChatMessage_codableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OpenClawChatMessage(
            id: "msg-1",
            role: "user",
            content: "Test message",
            timestamp: fixedDate
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OpenClawChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }

    func testOpenClawChatMessage_assistantRole() throws {
        let msg = OpenClawChatMessage(id: "a1", role: "assistant", content: "Response")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(OpenClawChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.content, "Response")
    }

    func testOpenClawChatMessage_emptyContent() throws {
        let msg = OpenClawChatMessage(id: "e1", role: "user", content: "")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(OpenClawChatMessage.self, from: data)
        XCTAssertEqual(decoded.content, "")
    }

    // MARK: - OpenClawConversation

    func testOpenClawConversation_defaultInitializer() {
        let conv = OpenClawConversation(sessionKey: "test:session")
        XCTAssertFalse(conv.id.isEmpty)
        XCTAssertEqual(conv.sessionKey, "test:session")
        XCTAssertEqual(conv.title, "New Conversation")
        XCTAssertTrue(conv.messages.isEmpty)
    }

    func testOpenClawConversation_customTitle() {
        let conv = OpenClawConversation(sessionKey: "sk", title: "My Chat")
        XCTAssertEqual(conv.title, "My Chat")
    }

    func testOpenClawConversation_codableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let message = OpenClawChatMessage(id: "m1", role: "user", content: "Hello", timestamp: fixedDate)
        let original = OpenClawConversation(
            id: "conv-1",
            sessionKey: "my:session",
            title: "Test Convo",
            messages: [message],
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OpenClawConversation.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sessionKey, original.sessionKey)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages[0].content, "Hello")
        XCTAssertEqual(decoded.createdAt, original.createdAt)
    }

    func testOpenClawConversation_emptyMessages() throws {
        let conv = OpenClawConversation(id: "c2", sessionKey: "sk", title: "Empty")
        let data = try encoder.encode(conv)
        let decoded = try decoder.decode(OpenClawConversation.self, from: data)
        XCTAssertTrue(decoded.messages.isEmpty)
    }

    func testOpenClawConversation_multipleMessages() throws {
        let m1 = OpenClawChatMessage(id: "m1", role: "user", content: "Hi")
        let m2 = OpenClawChatMessage(id: "m2", role: "assistant", content: "Hello!")
        let conv = OpenClawConversation(
            id: "c3",
            sessionKey: "sk",
            messages: [m1, m2]
        )
        let data = try encoder.encode(conv)
        let decoded = try decoder.decode(OpenClawConversation.self, from: data)
        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages[0].id, "m1")
        XCTAssertEqual(decoded.messages[1].id, "m2")
    }
}
