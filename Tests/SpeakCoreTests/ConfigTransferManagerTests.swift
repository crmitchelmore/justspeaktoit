import XCTest

@testable import SpeakCore

final class ConfigTransferManagerTests: XCTestCase {

    private let sut = ConfigTransferManager.shared

    // MARK: - Roundtrip encode/decode

    func testGenerateAndDecode_emptyPayload_roundtrips() throws {
        let encoded = try sut.generatePayload(secrets: [:], settings: [:])
        let decoded = try sut.decodePayload(encoded)
        XCTAssertTrue(decoded.secrets.isEmpty)
        XCTAssertTrue(decoded.settings.isEmpty)
        XCTAssertEqual(decoded.version, 1)
    }

    func testGenerateAndDecode_withSecrets_roundtrips() throws {
        let secrets = ["apiKey": "sk-test-12345"]
        let encoded = try sut.generatePayload(secrets: secrets, settings: [:])
        let decoded = try sut.decodePayload(encoded)
        XCTAssertEqual(decoded.secrets["apiKey"], "sk-test-12345")
    }

    func testGenerateAndDecode_withSettings_roundtrips() throws {
        let settings = ["selectedModel": "whisper-large", "darkMode": "true"]
        let encoded = try sut.generatePayload(secrets: [:], settings: settings)
        let decoded = try sut.decodePayload(encoded)
        XCTAssertEqual(decoded.settings["selectedModel"], "whisper-large")
        XCTAssertEqual(decoded.settings["darkMode"], "true")
    }

    func testGenerateAndDecode_withBothSecretsAndSettings_roundtrips() throws {
        let secrets = ["key1": "value1"]
        let settings = ["pref1": "value2"]
        let encoded = try sut.generatePayload(secrets: secrets, settings: settings)
        let decoded = try sut.decodePayload(encoded)
        XCTAssertEqual(decoded.secrets["key1"], "value1")
        XCTAssertEqual(decoded.settings["pref1"], "value2")
    }

    func testGenerateAndDecode_unicodeValues_roundtrips() throws {
        let secrets = ["apiKey": "tëst-kéy-🔑"]
        let encoded = try sut.generatePayload(secrets: secrets, settings: [:])
        let decoded = try sut.decodePayload(encoded)
        XCTAssertEqual(decoded.secrets["apiKey"], "tëst-kéy-🔑")
    }

    // MARK: - Obfuscation properties

    func testGeneratedPayload_isValidBase64() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:])
        XCTAssertNotNil(Data(base64Encoded: encoded), "Output should be valid base64")
    }

    func testGeneratedPayload_secretsAreObfuscated() throws {
        let encoded = try sut.generatePayload(secrets: ["apiKey": "supersecret"], settings: [:])
        let rawData = Data(base64Encoded: encoded)!
        let rawString = String(data: rawData, encoding: .utf8) ?? ""
        XCTAssertFalse(
            rawString.contains("supersecret"),
            "Obfuscated payload should not contain plaintext secrets"
        )
    }

    func testGeneratedPayload_isDeterministicForSameInput() throws {
        // Two invocations of generatePayload produce different base64 strings because
        // timestamps differ — but both should decode to the same secrets/settings.
        let secrets = ["key": "value"]
        let encoded1 = try sut.generatePayload(secrets: secrets, settings: [:])
        let encoded2 = try sut.generatePayload(secrets: secrets, settings: [:])
        let decoded1 = try sut.decodePayload(encoded1)
        let decoded2 = try sut.decodePayload(encoded2)
        XCTAssertEqual(decoded1.secrets["key"], decoded2.secrets["key"])
    }

    // MARK: - Decode errors

    func testDecodePayload_invalidBase64_throwsInvalidFormat() {
        XCTAssertThrowsError(try sut.decodePayload("not valid base64!!!")) { error in
            guard let transferError = error as? ConfigTransferError,
                  case .invalidFormat = transferError else {
                XCTFail("Expected ConfigTransferError.invalidFormat, got \(error)")
                return
            }
        }
    }

    func testDecodePayload_validBase64ButCorruptedData_throwsDecodingFailed() {
        // "Hello World" base64 — decodes to bytes that, after deobfuscation, won't be valid JSON
        XCTAssertThrowsError(try sut.decodePayload("SGVsbG8gV29ybGQ=")) { error in
            guard let transferError = error as? ConfigTransferError,
                  case .decodingFailed = transferError else {
                XCTFail("Expected ConfigTransferError.decodingFailed, got \(error)")
                return
            }
        }
    }

    func testDecodePayload_emptyString_throwsDecodingFailed() {
        XCTAssertThrowsError(try sut.decodePayload("")) { error in
            guard let transferError = error as? ConfigTransferError,
                  case .decodingFailed = transferError else {
                XCTFail("Expected ConfigTransferError.decodingFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Freshness validation

    func testValidatePayloadFreshness_newPayload_returnsTrue() {
        let payload = ConfigTransferPayload()
        XCTAssertTrue(sut.validatePayloadFreshness(payload))
    }

    func testValidatePayloadFreshness_expiredPayload_returnsFalse() {
        var payload = ConfigTransferPayload()
        payload.timestamp = Date(timeIntervalSinceNow: -660) // 11 minutes ago
        XCTAssertFalse(sut.validatePayloadFreshness(payload, maxAge: 600))
    }

    func testValidatePayloadFreshness_justUnderMaxAge_returnsTrue() {
        var payload = ConfigTransferPayload()
        payload.timestamp = Date(timeIntervalSinceNow: -30) // 30 seconds ago
        XCTAssertTrue(sut.validatePayloadFreshness(payload, maxAge: 60))
    }

    func testValidatePayloadFreshness_justOverMaxAge_returnsFalse() {
        var payload = ConfigTransferPayload()
        payload.timestamp = Date(timeIntervalSinceNow: -30) // 30 seconds ago
        XCTAssertFalse(sut.validatePayloadFreshness(payload, maxAge: 20))
    }

    func testValidatePayloadFreshness_defaultMaxAgeIs600Seconds() {
        var fresh = ConfigTransferPayload()
        fresh.timestamp = Date(timeIntervalSinceNow: -599) // just within default 10 min window
        XCTAssertTrue(sut.validatePayloadFreshness(fresh))

        var stale = ConfigTransferPayload()
        stale.timestamp = Date(timeIntervalSinceNow: -601) // just outside default window
        XCTAssertFalse(sut.validatePayloadFreshness(stale))
    }

    // MARK: - ConfigTransferError descriptions

    func testConfigTransferError_invalidFormat_hasDescription() {
        let error = ConfigTransferError.invalidFormat
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testConfigTransferError_payloadExpired_hasDescription() {
        let error = ConfigTransferError.payloadExpired
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testConfigTransferError_decodingFailed_hasDescription() {
        let error = ConfigTransferError.decodingFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }
}
