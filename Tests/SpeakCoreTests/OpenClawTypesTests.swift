import XCTest

@testable import SpeakCore

final class OpenClawTypesTests: XCTestCase {

    // MARK: - OpenClawConnectConfig construction

    func testConnectConfig_defaultValues_applied() {
        let config = OpenClawConnectConfig(
            gatewayURL: "wss://example.com",
            token: "tok123"
        )
        XCTAssertEqual(config.gatewayURL, "wss://example.com")
        XCTAssertEqual(config.token, "tok123")
        XCTAssertEqual(config.clientName, "speak-ios")
        XCTAssertEqual(config.sessionKey, "speak-ios:voice")
    }

    func testConnectConfig_customValues_overrideDefaults() {
        let config = OpenClawConnectConfig(
            gatewayURL: "ws://localhost:8080",
            token: "abc",
            clientName: "custom-client",
            sessionKey: "custom:session"
        )
        XCTAssertEqual(config.clientName, "custom-client")
        XCTAssertEqual(config.sessionKey, "custom:session")
    }

    // MARK: - OpenClawConnectConfig Codable round-trip

    func testConnectConfig_codableRoundTrip_preservesAllFields() throws {
        let original = OpenClawConnectConfig(
            gatewayURL: "wss://gateway.example.com:4443",
            token: "secret-token-xyz",
            clientName: "test-client",
            sessionKey: "test:key"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawConnectConfig.self, from: data)

        XCTAssertEqual(decoded.gatewayURL, original.gatewayURL)
        XCTAssertEqual(decoded.token, original.token)
        XCTAssertEqual(decoded.clientName, original.clientName)
        XCTAssertEqual(decoded.sessionKey, original.sessionKey)
    }

    // MARK: - OpenClawConnectionState

    func testConnectionState_disconnected() {
        let state = OpenClawConnectionState.disconnected
        if case .disconnected = state { } else {
            XCTFail("Expected disconnected")
        }
    }

    func testConnectionState_connecting() {
        let state = OpenClawConnectionState.connecting
        if case .connecting = state { } else {
            XCTFail("Expected connecting")
        }
    }

    func testConnectionState_connected() {
        let state = OpenClawConnectionState.connected
        if case .connected = state { } else {
            XCTFail("Expected connected")
        }
    }

    func testConnectionState_error_carriesMessage() {
        let state = OpenClawConnectionState.error("connection timed out")
        if case .error(let msg) = state {
            XCTAssertEqual(msg, "connection timed out")
        } else {
            XCTFail("Expected error state with message")
        }
    }

    // MARK: - OpenClawChatMessage construction

    func testChatMessage_defaultID_isUUIDShaped() {
        let msg = OpenClawChatMessage(role: "user", content: "Hello")
        XCTAssertFalse(msg.id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: msg.id), "Default id should be a valid UUID string")
    }

    func testChatMessage_explicitID_preserved() {
        let msg = OpenClawChatMessage(id: "fixed-id", role: "assistant", content: "Hi")
        XCTAssertEqual(msg.id, "fixed-id")
        XCTAssertEqual(msg.role, "assistant")
        XCTAssertEqual(msg.content, "Hi")
    }

    func testChatMessage_defaultIDs_areUnique() {
        let msg1 = OpenClawChatMessage(role: "user", content: "A")
        let msg2 = OpenClawChatMessage(role: "user", content: "B")
        XCTAssertNotEqual(msg1.id, msg2.id)
    }

    // MARK: - OpenClawChatMessage Codable round-trip

    func testChatMessage_codableRoundTrip_preservesAllFields() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let original = OpenClawChatMessage(
            id: "test-id-1",
            role: "user",
            content: "What's the weather?",
            timestamp: timestamp
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.timestamp.timeIntervalSinceReferenceDate,
                       original.timestamp.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
    }

    func testChatMessage_codableRoundTrip_assistantRole() throws {
        let original = OpenClawChatMessage(
            id: "asst-1",
            role: "assistant",
            content: "It is sunny today.",
            timestamp: Date(timeIntervalSinceReferenceDate: 2_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.content, "It is sunny today.")
    }

    // MARK: - OpenClawConversation construction

    func testConversation_defaultValues_applied() {
        let conv = OpenClawConversation(sessionKey: "s:k")
        XCTAssertEqual(conv.sessionKey, "s:k")
        XCTAssertEqual(conv.title, "New Conversation")
        XCTAssertTrue(conv.messages.isEmpty)
        XCTAssertFalse(conv.id.isEmpty)
    }

    func testConversation_explicitFields_preserved() {
        let msg = OpenClawChatMessage(id: "m1", role: "user", content: "Hey")
        let ts = Date(timeIntervalSinceReferenceDate: 500_000)
        let conv = OpenClawConversation(
            id: "conv-123",
            sessionKey: "my:session",
            title: "My Chat",
            messages: [msg],
            createdAt: ts,
            updatedAt: ts
        )
        XCTAssertEqual(conv.id, "conv-123")
        XCTAssertEqual(conv.title, "My Chat")
        XCTAssertEqual(conv.messages.count, 1)
        XCTAssertEqual(conv.messages.first?.id, "m1")
    }

    func testConversation_defaultIDs_areUnique() {
        let c1 = OpenClawConversation(sessionKey: "k1")
        let c2 = OpenClawConversation(sessionKey: "k2")
        XCTAssertNotEqual(c1.id, c2.id)
    }

    // MARK: - OpenClawConversation Codable round-trip

    func testConversation_codableRoundTrip_noMessages() throws {
        let ts = Date(timeIntervalSinceReferenceDate: 1_500_000)
        let original = OpenClawConversation(
            id: "c1",
            sessionKey: "sess:key",
            title: "Empty Chat",
            messages: [],
            createdAt: ts,
            updatedAt: ts
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sessionKey, original.sessionKey)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertTrue(decoded.messages.isEmpty)
    }

    func testConversation_codableRoundTrip_withMessages() throws {
        let msgTs = Date(timeIntervalSinceReferenceDate: 100_000)
        let convTs = Date(timeIntervalSinceReferenceDate: 200_000)
        let messages = [
            OpenClawChatMessage(id: "m1", role: "user", content: "Hello", timestamp: msgTs),
            OpenClawChatMessage(id: "m2", role: "assistant", content: "Hi there!", timestamp: msgTs),
        ]
        let original = OpenClawConversation(
            id: "c2",
            sessionKey: "chat:session",
            title: "Greeting",
            messages: messages,
            createdAt: convTs,
            updatedAt: convTs
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: data)

        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages[0].id, "m1")
        XCTAssertEqual(decoded.messages[1].content, "Hi there!")
    }

    func testConversation_codableRoundTrip_preservesDates() throws {
        let createdAt = Date(timeIntervalSinceReferenceDate: 300_000)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 400_000)
        let original = OpenClawConversation(
            id: "c3",
            sessionKey: "k",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawConversation.self, from: data)

        XCTAssertEqual(
            decoded.createdAt.timeIntervalSinceReferenceDate,
            createdAt.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
        XCTAssertEqual(
            decoded.updatedAt.timeIntervalSinceReferenceDate,
            updatedAt.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }
}
