import XCTest

@testable import SpeakCore

final class TransportMessageCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        return jsonEncoder
    }()

    private let decoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        return jsonDecoder
    }()

    // MARK: - .ping / .pong (no payload)

    func testPing_roundtrip() throws {
        let original = TransportMessage.ping
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .ping = decoded else {
            XCTFail("Expected .ping, got \(decoded)")
            return
        }
    }

    func testPong_roundtrip() throws {
        let original = TransportMessage.pong
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .pong = decoded else {
            XCTFail("Expected .pong, got \(decoded)")
            return
        }
    }

    func testPing_encodesTypeField() throws {
        let data = try encoder.encode(TransportMessage.ping)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "ping")
        XCTAssertNil(json?["payload"])
    }

    // MARK: - .hello

    func testHello_roundtrip() throws {
        let msg = HelloMessage(protocolVersion: 2, deviceName: "iPhone 15", deviceId: "abc-123")
        let original = TransportMessage.hello(msg)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .hello(let result) = decoded else {
            XCTFail("Expected .hello"); return
        }
        XCTAssertEqual(result.protocolVersion, 2)
        XCTAssertEqual(result.deviceName, "iPhone 15")
        XCTAssertEqual(result.deviceId, "abc-123")
    }

    func testHello_defaultProtocolVersion() {
        let msg = HelloMessage(deviceName: "Test", deviceId: "id")
        XCTAssertEqual(msg.protocolVersion, SpeakTransportProtocolVersion)
    }

    func testHello_encodesTypeField() throws {
        let msg = HelloMessage(deviceName: "Mac", deviceId: "d")
        let data = try encoder.encode(TransportMessage.hello(msg))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "hello")
    }

    // MARK: - .authenticate

    func testAuthenticate_roundtrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = AuthenticateMessage(pairingCode: "123456", timestamp: date)
        let data = try encoder.encode(TransportMessage.authenticate(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .authenticate(let result) = decoded else {
            XCTFail("Expected .authenticate"); return
        }
        XCTAssertEqual(result.pairingCode, "123456")
        // Timestamps encoded as ISO8601 may lose sub-second precision — compare to the second
        XCTAssertEqual(result.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - .authResult

    func testAuthResult_success_roundtrip() throws {
        let msg = AuthResultMessage(success: true, sessionToken: "tok-xyz")
        let data = try encoder.encode(TransportMessage.authResult(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .authResult(let result) = decoded else {
            XCTFail("Expected .authResult"); return
        }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.sessionToken, "tok-xyz")
        XCTAssertNil(result.errorMessage)
    }

    func testAuthResult_failure_roundtrip() throws {
        let msg = AuthResultMessage(success: false, errorMessage: "Bad code")
        let data = try encoder.encode(TransportMessage.authResult(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .authResult(let result) = decoded else {
            XCTFail("Expected .authResult"); return
        }
        XCTAssertFalse(result.success)
        XCTAssertNil(result.sessionToken)
        XCTAssertEqual(result.errorMessage, "Bad code")
    }

    // MARK: - .sessionStart

    func testSessionStart_roundtrip() throws {
        let msg = SessionStartMessage(sessionId: "s1", model: "deepgram", language: "fr-FR")
        let data = try encoder.encode(TransportMessage.sessionStart(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .sessionStart(let result) = decoded else {
            XCTFail("Expected .sessionStart"); return
        }
        XCTAssertEqual(result.sessionId, "s1")
        XCTAssertEqual(result.model, "deepgram")
        XCTAssertEqual(result.language, "fr-FR")
    }

    func testSessionStart_defaultLanguage() {
        let msg = SessionStartMessage(sessionId: "s2", model: "whisper")
        XCTAssertEqual(msg.language, "en-US")
    }

    // MARK: - .sessionEnd

    func testSessionEnd_roundtrip() throws {
        let msg = SessionEndMessage(sessionId: "s1", finalText: "Hello world", duration: 12.5, wordCount: 2)
        let data = try encoder.encode(TransportMessage.sessionEnd(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .sessionEnd(let result) = decoded else {
            XCTFail("Expected .sessionEnd"); return
        }
        XCTAssertEqual(result.sessionId, "s1")
        XCTAssertEqual(result.finalText, "Hello world")
        XCTAssertEqual(result.wordCount, 2)
        XCTAssertEqual(result.duration, 12.5, accuracy: 0.001)
    }

    // MARK: - .transcriptChunk

    func testTranscriptChunk_roundtrip() throws {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let msg = TranscriptChunkMessage(
            sessionId: "s1",
            sequenceNumber: 7,
            text: "Hi there",
            isFinal: true,
            timestamp: date
        )
        let data = try encoder.encode(TransportMessage.transcriptChunk(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .transcriptChunk(let result) = decoded else {
            XCTFail("Expected .transcriptChunk"); return
        }
        XCTAssertEqual(result.sequenceNumber, 7)
        XCTAssertEqual(result.text, "Hi there")
        XCTAssertTrue(result.isFinal)
    }

    // MARK: - .ack

    func testAck_roundtrip() throws {
        let msg = AckMessage(sequenceNumber: 42)
        let data = try encoder.encode(TransportMessage.ack(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .ack(let result) = decoded else {
            XCTFail("Expected .ack"); return
        }
        XCTAssertEqual(result.sequenceNumber, 42)
    }

    // MARK: - .error

    func testError_roundtrip() throws {
        let msg = ErrorMessage(code: 404, message: "Not found")
        let data = try encoder.encode(TransportMessage.error(msg))
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .error(let result) = decoded else {
            XCTFail("Expected .error"); return
        }
        XCTAssertEqual(result.code, 404)
        XCTAssertEqual(result.message, "Not found")
    }

    func testError_staticConstants() {
        XCTAssertEqual(ErrorMessage.authenticationFailed.code, 401)
        XCTAssertEqual(ErrorMessage.protocolMismatch.code, 400)
        XCTAssertEqual(ErrorMessage.sessionNotFound.code, 404)
        XCTAssertFalse(ErrorMessage.authenticationFailed.message.isEmpty)
        XCTAssertFalse(ErrorMessage.protocolMismatch.message.isEmpty)
        XCTAssertFalse(ErrorMessage.sessionNotFound.message.isEmpty)
    }

    // MARK: - Unknown type

    func testDecode_unknownType_fallsBackWithoutThrowing() throws {
        let json = #"{"type":"settingsSync","payload":{"future":true}}"#
        let data = Data(json.utf8)
        let decoded = try decoder.decode(TransportMessage.self, from: data)
        guard case .unknown(let type) = decoded else {
            XCTFail("Expected .unknown, got \(decoded)")
            return
        }
        XCTAssertEqual(type, "settingsSync")
    }

    // MARK: - Constants

    func testProtocolVersion_isVersion2() {
        XCTAssertEqual(SpeakTransportProtocolVersion, 2)
    }

    func testServiceType_isValidMultipeerServiceType() {
        XCTAssertEqual(SpeakTransportServiceType, "speaktransport")
        XCTAssertTrue(isValidSpeakTransportServiceType(SpeakTransportServiceType))
        XCTAssertLessThanOrEqual(SpeakTransportServiceType.count, 15)
        XCTAssertFalse(SpeakTransportServiceType.contains("_"))
        XCTAssertFalse(SpeakTransportServiceType.contains("."))
    }

    func testBonjourServices_includeTcpAndUdpDeclarations() {
        XCTAssertEqual(SpeakTransportBonjourServices, ["_speaktransport._tcp", "_speaktransport._udp"])
    }

    func testInvitationContext_roundtrip() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let context = PairingInvitationContext(
            protocolVersion: 2,
            deviceID: "ios-device",
            deviceName: "Chris's iPhone",
            timestamp: date,
            pairingCode: "ABCDE-FGHIJ"
        )

        let data = try encoder.encode(context)
        let decoded = try decoder.decode(PairingInvitationContext.self, from: data)

        XCTAssertEqual(decoded.protocolVersion, 2)
        XCTAssertEqual(decoded.deviceID, "ios-device")
        XCTAssertEqual(decoded.deviceName, "Chris's iPhone")
        XCTAssertEqual(decoded.pairingCode, "ABCDE-FGHIJ")
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1.0)
    }

    func testInvitationContext_freshnessUsesTolerance() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let fresh = PairingInvitationContext(
            deviceID: "ios-device",
            deviceName: "iPhone",
            timestamp: now.addingTimeInterval(-30),
            pairingCode: "ABCDE-FGHIJ"
        )
        let stale = PairingInvitationContext(
            deviceID: "ios-device",
            deviceName: "iPhone",
            timestamp: now.addingTimeInterval(-180),
            pairingCode: "ABCDE-FGHIJ"
        )

        XCTAssertTrue(fresh.isFresh(now: now, tolerance: 120))
        XCTAssertFalse(stale.isFresh(now: now, tolerance: 120))
    }
}
