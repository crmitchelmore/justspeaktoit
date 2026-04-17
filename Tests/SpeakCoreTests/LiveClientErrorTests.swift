import XCTest

@testable import SpeakCore

final class LiveClientErrorTests: XCTestCase {

    // MARK: - DeepgramLiveError

    func testDeepgramError_invalidURL_hasDescription() {
        let error = DeepgramLiveError.invalidURL
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("url") ?? false)
    }

    func testDeepgramError_connectionFailed_hasDescription() {
        let error = DeepgramLiveError.connectionFailed
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("connect") ?? false)
    }

    func testDeepgramError_sendFailed_hasDescription() {
        let error = DeepgramLiveError.sendFailed
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("send") ?? false)
    }

    func testDeepgramError_missingAPIKey_hasDescription() {
        let error = DeepgramLiveError.missingAPIKey
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("api key") ?? false)
    }

    func testDeepgramError_allCases_haveNonEmptyDescriptions() {
        let errors: [DeepgramLiveError] = [.invalidURL, .connectionFailed, .sendFailed, .missingAPIKey]
        for error in errors {
            XCTAssertFalse(
                error.errorDescription?.isEmpty ?? true,
                "\(error) should have a non-empty error description"
            )
        }
    }

    // MARK: - ElevenLabsLiveError

    func testElevenLabsError_invalidURL_hasDescription() {
        let error = ElevenLabsLiveError.invalidURL
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("url") ?? false)
    }

    func testElevenLabsError_connectionFailed_hasDescription() {
        let error = ElevenLabsLiveError.connectionFailed
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("connect") ?? false)
    }

    func testElevenLabsError_sendFailed_hasDescription() {
        let error = ElevenLabsLiveError.sendFailed
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("send") ?? false)
    }

    func testElevenLabsError_missingAPIKey_hasDescription() {
        let error = ElevenLabsLiveError.missingAPIKey
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("api key") ?? false)
    }

    func testElevenLabsError_allCases_haveNonEmptyDescriptions() {
        let errors: [ElevenLabsLiveError] = [.invalidURL, .connectionFailed, .sendFailed, .missingAPIKey]
        for error in errors {
            XCTAssertFalse(
                error.errorDescription?.isEmpty ?? true,
                "\(error) should have a non-empty error description"
            )
        }
    }

    // MARK: - Error as LocalizedError (protocol conformance check)

    func testDeepgramError_conformsToLocalizedError() {
        let error: any LocalizedError = DeepgramLiveError.missingAPIKey
        XCTAssertNotNil(error.errorDescription)
    }

    func testElevenLabsError_conformsToLocalizedError() {
        let error: any LocalizedError = ElevenLabsLiveError.missingAPIKey
        XCTAssertNotNil(error.errorDescription)
    }

    // MARK: - Error descriptions are distinct

    func testDeepgramError_allDescriptionsAreDistinct() {
        let descriptions = [
            DeepgramLiveError.invalidURL.errorDescription,
            DeepgramLiveError.connectionFailed.errorDescription,
            DeepgramLiveError.sendFailed.errorDescription,
            DeepgramLiveError.missingAPIKey.errorDescription
        ]
        let unique = Set(descriptions.compactMap { $0 })
        XCTAssertEqual(unique.count, 4, "All Deepgram error descriptions should be distinct")
    }

    func testElevenLabsError_allDescriptionsAreDistinct() {
        let descriptions = [
            ElevenLabsLiveError.invalidURL.errorDescription,
            ElevenLabsLiveError.connectionFailed.errorDescription,
            ElevenLabsLiveError.sendFailed.errorDescription,
            ElevenLabsLiveError.missingAPIKey.errorDescription
        ]
        let unique = Set(descriptions.compactMap { $0 })
        XCTAssertEqual(unique.count, 4, "All ElevenLabs error descriptions should be distinct")
    }

    // MARK: - ChatMessage from LLMProtocols

    func testChatMessageRole_rawValues() {
        XCTAssertEqual(ChatMessage.Role.system.rawValue, "system")
        XCTAssertEqual(ChatMessage.Role.user.rawValue, "user")
        XCTAssertEqual(ChatMessage.Role.assistant.rawValue, "assistant")
    }

    func testChatMessageRole_decodableFromString() throws {
        let json = "\"user\""
        let data = json.data(using: .utf8)!
        let role = try JSONDecoder().decode(ChatMessage.Role.self, from: data)
        XCTAssertEqual(role, .user)
    }

    func testChatMessage_defaultID_isUnique() {
        let firstMessage = ChatMessage(role: .user, content: "Hello")
        let secondMessage = ChatMessage(role: .user, content: "Hello")
        XCTAssertNotEqual(firstMessage.id, secondMessage.id)
    }

    func testChatMessage_codableRoundTrip() throws {
        let original = ChatMessage(role: .assistant, content: "How can I help?")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
    }

    func testChatMessage_hashable_deduplication() {
        let msg = ChatMessage(role: .user, content: "Hi")
        var set = Set<ChatMessage>()
        set.insert(msg)
        set.insert(msg)
        XCTAssertEqual(set.count, 1)
    }
}
