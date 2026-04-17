import XCTest

@testable import SpeakCore

final class OpenClawTypesTests: XCTestCase {

    // MARK: - OpenClawConnectConfig

    func testConnectConfig_defaultValues() {
        let config = OpenClawConnectConfig(gatewayURL: "ws://localhost:8080", token: "tok")
        XCTAssertEqual(config.gatewayURL, "ws://localhost:8080")
        XCTAssertEqual(config.token, "tok")
        XCTAssertEqual(config.clientName, "speak-ios")
        XCTAssertEqual(config.sessionKey, "speak-ios:voice")
    }

    func testConnectConfig_customValues() {
        let config = OpenClawConnectConfig(
            gatewayURL: "wss://gateway.example.com",
            token: "secret-token",
            clientName: "speak-mac",
            sessionKey: "speak-mac:custom"
        )
        XCTAssertEqual(config.clientName, "speak-mac")
        XCTAssertEqual(config.sessionKey, "speak-mac:custom")
    }

    func testConnectConfig_codableRoundTrip() throws {
        let original = OpenClawConnectConfig(
            gatewayURL: "wss://host:9000",
            token: "abc123",
            clientName: "test-client",
            sessionKey: "test:session"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenClawConnectConfig.self, from: data)
        XCTAssertEqual(decoded.gatewayURL, original.gatewayURL)
        XCTAssertEqual(decoded.token, original.token)
        XCTAssertEqual(decoded.clientName, original.clientName)
        XCTAssertEqual(decoded.sessionKey, original.sessionKey)
    }

    // MARK: - OpenClawConnectionState

    func testConnectionState_disconnected_isDistinct() {
        if case .disconnected = OpenClawConnectionState.disconnected {
            // pass
        } else {
            XCTFail("Expected .disconnected")
        }
    }

    func testConnectionState_connecting_isDistinct() {
        if case .connecting = OpenClawConnectionState.connecting {
            // pass
        } else {
            XCTFail("Expected .connecting")
        }
    }

    func testConnectionState_connected_isDistinct() {
        if case .connected = OpenClawConnectionState.connected {
            // pass
        } else {
            XCTFail("Expected .connected")
        }
    }

    func testConnectionState_error_carriesMessage() {
        let msg = "connection refused"
        if case .error(let errorMessage) = OpenClawConnectionState.error(msg) {
            XCTAssertEqual(errorMessage, msg)
        } else {
            XCTFail("Expected .error with message")
        }
    }

    // MARK: - OpenClawChatMessage

    func testChatMessage_defaultID_isUUID() {
        let msg = OpenClawChatMessage(role: "user", content: "Hello")
        XCTAssertFalse(msg.id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: msg.id))
    }

    func testChatMessage_defaultID_isUnique() {
        let firstMessage = OpenClawChatMessage(role: "user", content: "A")
        let secondMessage = OpenClawChatMessage(role: "user", content: "B")
        XCTAssertNotEqual(firstMessage.id, secondMessage.id)
    }

    func testChatMessage_customID() {
        let msg = OpenClawChatMessage(id: "custom-id", role: "assistant", content: "Hi")
        XCTAssertEqual(msg.id, "custom-id")
        XCTAssertEqual(msg.role, "assistant")
        XCTAssertEqual(msg.content, "Hi")
    }

    func testChatMessage_defaultTimestamp_isRecent() {
        let before = Date()
        let msg = OpenClawChatMessage(role: "user", content: "time test")
        let after = Date()
        XCTAssertGreaterThanOrEqual(msg.timestamp, before)
        XCTAssertLessThanOrEqual(msg.timestamp, after)
    }

    func testChatMessage_codableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OpenClawChatMessage(
            id: "msg-1",
            role: "assistant",
            content: "How can I help?",
            timestamp: fixedDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OpenClawChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970, accuracy: 1.0)
    }

    func testChatMessage_unicodeContent() throws {
        let msg = OpenClawChatMessage(role: "user", content: "こんにちは 🌸")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)
        XCTAssertEqual(decoded.content, "こんにちは 🌸")
    }

    // MARK: - OpenClawConversation

    func testConversation_defaultValues() {
        let conv = OpenClawConversation(sessionKey: "session:1")
        XCTAssertFalse(conv.id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: conv.id))
        XCTAssertEqual(conv.sessionKey, "session:1")
        XCTAssertEqual(conv.title, "New Conversation")
        XCTAssertTrue(conv.messages.isEmpty)
    }

    func testConversation_defaultID_isUnique() {
        let firstConversation = OpenClawConversation(sessionKey: "s1")
        let secondConversation = OpenClawConversation(sessionKey: "s1")
        XCTAssertNotEqual(firstConversation.id, secondConversation.id)
    }

    func testConversation_withMessages() {
        let msg = OpenClawChatMessage(id: "m1", role: "user", content: "Hi")
        let conv = OpenClawConversation(
            id: "conv-1",
            sessionKey: "speak:session",
            title: "Test Chat",
            messages: [msg]
        )
        XCTAssertEqual(conv.messages.count, 1)
        XCTAssertEqual(conv.messages.first?.content, "Hi")
        XCTAssertEqual(conv.title, "Test Chat")
    }

    func testConversation_codableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = OpenClawChatMessage(id: "m1", role: "user", content: "Hello", timestamp: fixedDate)
        let original = OpenClawConversation(
            id: "conv-1",
            sessionKey: "speak:ios:voice",
            title: "My Chat",
            messages: [msg],
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OpenClawConversation.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sessionKey, original.sessionKey)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages.first?.content, "Hello")
    }

    // MARK: - OpenClawError

    func testOpenClawError_encodingFailed_hasDescription() {
        let error = OpenClawError.encodingFailed
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("encod") ?? false)
    }

    func testOpenClawError_serverError_containsMessage() {
        let error = OpenClawError.serverError("internal server error")
        XCTAssertTrue(error.errorDescription?.contains("internal server error") ?? false)
    }

    func testOpenClawError_notConnected_hasDescription() {
        let error = OpenClawError.notConnected
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("connect") ?? false)
    }

    func testOpenClawError_invalidResponse_hasDescription() {
        let error = OpenClawError.invalidResponse
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("response") ?? false)
    }
}
