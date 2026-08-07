import Foundation
import XCTest

@testable import SpeakCore

/// Rejection behavior for malformed transport frames. The mac server decodes
/// every incoming frame with an iso8601 JSONDecoder (see TransportConnection),
/// so these tests pin down exactly which broken inputs are rejected and which
/// unknown-but-harmless extras are tolerated for forward compatibility.
final class TransportMalformedFrameTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        return jsonDecoder
    }()

    private func assertRejected(_ json: String, _ reason: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try decoder.decode(TransportMessage.self, from: Data(json.utf8)),
            reason, file: file, line: line
        )
    }

    // MARK: - Structurally invalid frames

    func testEmptyData_isRejected() {
        XCTAssertThrowsError(try decoder.decode(TransportMessage.self, from: Data()))
    }

    func testNonJSONGarbage_isRejected() {
        let garbage = Data([0x00, 0xFF, 0x13, 0x37, 0xDE, 0xAD])
        XCTAssertThrowsError(try decoder.decode(TransportMessage.self, from: garbage))
    }

    func testTruncatedJSON_isRejected() {
        assertRejected(#"{"type":"hello","payload":{"deviceNa"#, "truncated frame must throw")
    }

    func testTopLevelArray_isRejected() {
        assertRejected(#"[{"type":"ping"}]"#, "array frame must throw")
    }

    func testMissingTypeKey_isRejected() {
        assertRejected(#"{"payload":{"sequenceNumber":1}}"#, "frame without type must throw")
    }

    func testNullType_isRejected() {
        assertRejected(#"{"type":null}"#, "null type must throw")
    }

    // MARK: - Missing or invalid payloads

    func testPayloadCarryingTypes_withMissingPayload_areRejected() {
        for type in ["hello", "authenticate", "authResult", "sessionStart",
                     "sessionEnd", "transcriptChunk", "ack", "error"] {
            assertRejected(#"{"type":"\#(type)"}"#, "\(type) without payload must throw")
        }
    }

    func testPayloadCarryingTypes_withNullPayload_areRejected() {
        for type in ["hello", "authenticate", "ack", "error"] {
            assertRejected(#"{"type":"\#(type)","payload":null}"#,
                           "\(type) with null payload must throw")
        }
    }

    func testHello_withMissingRequiredFields_isRejected() {
        assertRejected(#"{"type":"hello","payload":{}}"#, "empty hello payload must throw")
        assertRejected(
            #"{"type":"hello","payload":{"deviceName":"iPhone","deviceId":"d1"}}"#,
            "hello without protocolVersion must throw"
        )
    }

    func testAck_withWrongPayloadFieldType_isRejected() {
        assertRejected(
            #"{"type":"ack","payload":{"sequenceNumber":"seven"}}"#,
            "string sequenceNumber must throw"
        )
    }

    func testTranscriptChunk_withInvalidTimestamp_isRejected() {
        assertRejected(
            #"""
            {"type":"transcriptChunk","payload":{"sessionId":"s1","sequenceNumber":1,
            "text":"hi","isFinal":true,"timestamp":"not-a-date"}}
            """#,
            "unparseable iso8601 timestamp must throw"
        )
    }

    func testAuthenticate_withWrongPayloadShape_isRejected() {
        assertRejected(
            #"{"type":"authenticate","payload":[1,2,3]}"#,
            "array payload must throw"
        )
    }

    // MARK: - Forward compatibility

    func testUnknownExtraPayloadFields_areTolerated() throws {
        let json = #"""
        {"type":"hello","payload":{"protocolVersion":1,"deviceName":"iPhone",
        "deviceId":"d1","futureField":"ignored","anotherFuture":42}}
        """#
        let decoded = try decoder.decode(TransportMessage.self, from: Data(json.utf8))
        guard case .hello(let hello) = decoded else {
            XCTFail("Expected .hello"); return
        }
        XCTAssertEqual(hello.protocolVersion, 1)
        XCTAssertEqual(hello.deviceId, "d1")
    }

    func testUnknownExtraTopLevelFields_areTolerated() throws {
        let json = #"{"type":"pong","futureEnvelope":true}"#
        let decoded = try decoder.decode(TransportMessage.self, from: Data(json.utf8))
        guard case .pong = decoded else {
            XCTFail("Expected .pong"); return
        }
    }

    func testPing_withSpuriousPayload_isTolerated() throws {
        // Payload-less types ignore an unexpected payload instead of failing the
        // connection; a newer peer may attach diagnostics to keepalives.
        let json = #"{"type":"ping","payload":{"future":"stuff"}}"#
        let decoded = try decoder.decode(TransportMessage.self, from: Data(json.utf8))
        guard case .ping = decoded else {
            XCTFail("Expected .ping"); return
        }
    }
}

/// Pairing logic backing transport authentication. PairingManager persists via
/// UserDefaults.standard (the test-runner domain here); every touched key is
/// snapshotted and restored so nothing leaks between tests.
final class TransportPairingManagerTests: XCTestCase {
    private let codeKey = "speakTransportPairingCode"
    private let devicesKey = "speakTransportPairedDevices"
    private var savedCode: String?
    private var savedDevices: [String: String]?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedCode = defaults.string(forKey: codeKey)
        savedDevices = defaults.dictionary(forKey: devicesKey) as? [String: String]
        defaults.removeObject(forKey: codeKey)
        defaults.removeObject(forKey: devicesKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedCode {
            defaults.set(savedCode, forKey: codeKey)
        } else {
            defaults.removeObject(forKey: codeKey)
        }
        if let savedDevices {
            defaults.set(savedDevices, forKey: devicesKey)
        } else {
            defaults.removeObject(forKey: devicesKey)
        }
        super.tearDown()
    }

    func testPairingCode_isSixDigitsAndStableAcrossReads() {
        let manager = PairingManager.shared
        let first = manager.pairingCode
        XCTAssertEqual(first.count, 6)
        XCTAssertTrue(first.allSatisfy(\.isNumber))
        XCTAssertEqual(manager.pairingCode, first, "Code must not change between reads")
    }

    func testValidatePairingCode_acceptsOwnCodeAndRejectsOthers() {
        let manager = PairingManager.shared
        let code = manager.pairingCode
        XCTAssertTrue(manager.validatePairingCode(code))
        XCTAssertFalse(manager.validatePairingCode("not-the-code"))
        XCTAssertFalse(manager.validatePairingCode(""))
    }

    func testAddAndRemovePairedDevice() {
        let manager = PairingManager.shared
        manager.addPairedDevice(id: "device-1", name: "iPhone")
        XCTAssertTrue(manager.isDevicePaired(id: "device-1"))
        XCTAssertEqual(manager.pairedDevices["device-1"], "iPhone")

        manager.removePairedDevice(id: "device-1")
        XCTAssertFalse(manager.isDevicePaired(id: "device-1"))
        XCTAssertNil(manager.pairedDevices["device-1"])
    }

    func testRegeneratePairingCode_invalidatesExistingPairings() {
        let manager = PairingManager.shared
        _ = manager.pairingCode
        manager.addPairedDevice(id: "device-1", name: "iPhone")

        let newCode = manager.regeneratePairingCode()

        XCTAssertEqual(newCode.count, 6)
        XCTAssertTrue(newCode.allSatisfy(\.isNumber))
        XCTAssertEqual(manager.pairingCode, newCode, "Regenerated code must persist")
        XCTAssertTrue(manager.pairedDevices.isEmpty, "Regeneration must clear pairings")
        XCTAssertFalse(manager.isDevicePaired(id: "device-1"))
    }
}
