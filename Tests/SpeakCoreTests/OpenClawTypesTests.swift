import XCTest

@testable import SpeakCore

final class OpenClawTypesTests: XCTestCase {

    // MARK: - OpenClawConnectConfig

    func testOpenClawConnectConfig_defaults() {
        let config = OpenClawConnectConfig(
            gatewayURL: "wss://example.com",
            token: "tok123"
        )
        XCTAssertEqual(config.gatewayURL, "wss://example.com")
        XCTAssertEqual(config.token, "tok123")
        XCTAssertEqual(config.clientName, "speak-ios")
        XCTAssertEqual(config.sessionKey, "speak-ios:voice")
    }

    func testOpenClawConnectConfig_customValues() {
        let config = OpenClawConnectConfig(
            gatewayURL: "ws://localhost:8080",
            token: "secret",
            clientName: "speak-mac",
            sessionKey: "speak-mac:voice"
        )
        XCTAssertEqual(config.clientName, "speak-mac")
        XCTAssertEqual(config.sessionKey, "speak-mac:voice")
    }

    func testOpenClawConnectConfig_codableRoundTrip() throws {
        let config = OpenClawConnectConfig(
            gatewayURL: "wss://gateway.example.com",
            token: "bearer-token",
            clientName: "client-a",
            sessionKey: "session-key-a"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OpenClawConnectConfig.self, from: data)
        XCTAssertEqual(decoded.gatewayURL, config.gatewayURL)
        XCTAssertEqual(decoded.token, config.token)
        XCTAssertEqual(decoded.clientName, config.clientName)
        XCTAssertEqual(decoded.sessionKey, config.sessionKey)
    }

    // MARK: - OpenClawChatMessage

    func testOpenClawChatMessage_defaultIDIsNotEmpty() {
        let msg = OpenClawChatMessage(role: "user", content: "Hello")
        XCTAssertFalse(msg.id.isEmpty)
    }

    func testOpenClawChatMessage_twoDefaultMessages_haveDistinctIDs() {
        let m1 = OpenClawChatMessage(role: "user", content: "A")
        let m2 = OpenClawChatMessage(role: "user", content: "B")
        XCTAssertNotEqual(m1.id, m2.id)
    }

    func testOpenClawChatMessage_codableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OpenClawChatMessage(
            id: "msg-42",
            role: "assistant",
            content: "How can I help?",
            timestamp: fixedDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OpenClawChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, "msg-42")
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.content, "How can I help?")
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, fixedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testOpenClawChatMessage_userRole() {
        let msg = OpenClawChatMessage(role: "user", content: "Transcribe this")
        XCTAssertEqual(msg.role, "user")
    }

    // MARK: - OpenClawConversation

    func testOpenClawConversation_defaultTitle() {
        let conv = OpenClawConversation(sessionKey: "sess-1")
        XCTAssertEqual(conv.title, "New Conversation")
        XCTAssertTrue(conv.messages.isEmpty)
    }

    func testOpenClawConversation_defaultIDIsNotEmpty() {
        let conv = OpenClawConversation(sessionKey: "sess-1")
        XCTAssertFalse(conv.id.isEmpty)
    }

    func testOpenClawConversation_twoDefaultConversations_haveDistinctIDs() {
        let c1 = OpenClawConversation(sessionKey: "s1")
        let c2 = OpenClawConversation(sessionKey: "s2")
        XCTAssertNotEqual(c1.id, c2.id)
    }

    func testOpenClawConversation_withMessages_codableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = OpenClawChatMessage(
            id: "m1",
            role: "user",
            content: "Hi",
            timestamp: fixedDate
        )
        let conv = OpenClawConversation(
            id: "conv-1",
            sessionKey: "key-1",
            title: "Chat about X",
            messages: [msg],
            createdAt: fixedDate,
            updatedAt: fixedDate
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let data = try encoder.encode(conv)
        let decoded = try decoder.decode(OpenClawConversation.self, from: data)

        XCTAssertEqual(decoded.id, "conv-1")
        XCTAssertEqual(decoded.sessionKey, "key-1")
        XCTAssertEqual(decoded.title, "Chat about X")
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages.first?.content, "Hi")
    }

    func testOpenClawConversation_emptyMessages_codableRoundTrip() throws {
        let conv = OpenClawConversation(
            id: "c2",
            sessionKey: "k2",
            title: "Empty"
        )
        let data = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: data)
        XCTAssertTrue(decoded.messages.isEmpty)
    }
}
