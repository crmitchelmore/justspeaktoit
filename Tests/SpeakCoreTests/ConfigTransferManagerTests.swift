import Foundation
import XCTest

@testable import SpeakCore

final class ConfigTransferManagerTests: XCTestCase {

    private let sut = ConfigTransferManager.shared

    func testGenerateAndDecode_v2SettingsPayload_roundtripsSupportedSettings() throws {
        // Arrange
        let settings = ["selectedModel": "apple/local/SFSpeechRecognizer"]

        // Act
        let encoded = try sut.generatePayload(settings: settings)
        let decoded = try sut.decodePayload(encoded)

        // Assert
        XCTAssertEqual(decoded.version, 2)
        XCTAssertTrue(decoded.secrets.isEmpty)
        XCTAssertEqual(decoded.settings, settings)
    }

    func testGeneratePayload_v2Payload_isPlainJSONWithoutSecretsField() throws {
        // Arrange
        let settings = ["selectedModel": "apple/local/SFSpeechRecognizer"]

        // Act
        let encoded = try sut.generatePayload(settings: settings)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedSettings = try XCTUnwrap(object["settings"] as? [String: String])

        // Assert
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertNil(object["secrets"])
        XCTAssertEqual(decodedSettings, settings)
    }

    func testGeneratePayload_nonEmptySecrets_throwsSecretTransferUnsupported() {
        // Arrange
        let secrets = ["legacyCredential": "credential-value"]

        // Act / Assert
        XCTAssertThrowsError(try sut.generatePayload(secrets: secrets, settings: [:])) { error in
            guard case ConfigTransferError.secretTransferUnsupported = error else {
                XCTFail("Expected ConfigTransferError.secretTransferUnsupported, got \(error)")
                return
            }
        }
    }

    func testGeneratePayload_unsupportedSettingKey_throwsUnsupportedSettings() {
        // Arrange
        let settings = ["unsupportedSetting": "placeholder"]

        // Act / Assert
        XCTAssertThrowsError(try sut.generatePayload(settings: settings)) { error in
            guard case ConfigTransferError.unsupportedSettings(let keys) = error else {
                XCTFail("Expected ConfigTransferError.unsupportedSettings, got \(error)")
                return
            }
            XCTAssertEqual(keys, ["unsupportedSetting"])
        }
    }

    func testDecodePayload_unsupportedVersion_throwsUnsupportedVersion() throws {
        // Arrange
        let encoded = try encodeCurrentPayload(
            ConfigTransferPayload(
                settings: ["selectedModel": "apple/local/SFSpeechRecognizer"],
                version: 3
            )
        )

        // Act / Assert
        XCTAssertThrowsError(try sut.decodePayload(encoded)) { error in
            guard case ConfigTransferError.unsupportedVersion(let version) = error else {
                XCTFail("Expected ConfigTransferError.unsupportedVersion, got \(error)")
                return
            }
            XCTAssertEqual(version, 3)
        }
    }

    func testDecodePayload_unsupportedSettingKey_throwsUnsupportedSettings() throws {
        // Arrange
        let encoded = try encodeCurrentPayload(
            ConfigTransferPayload(
                settings: [
                    "selectedModel": "apple/local/SFSpeechRecognizer",
                    "unsupportedSetting": "placeholder"
                ]
            )
        )

        // Act / Assert
        XCTAssertThrowsError(try sut.decodePayload(encoded)) { error in
            guard case ConfigTransferError.unsupportedSettings(let keys) = error else {
                XCTFail("Expected ConfigTransferError.unsupportedSettings, got \(error)")
                return
            }
            XCTAssertEqual(keys, ["unsupportedSetting"])
        }
    }

    func testDecodePayload_legacyXORSettingsOnlyPayload_acceptsSupportedSettings() throws {
        // Arrange
        let settings = ["selectedModel": "apple/local/SFSpeechRecognizer"]
        let encoded = try encodeLegacyXORPayload(settings: settings)

        // Act
        let decoded = try sut.decodePayload(encoded)

        // Assert
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.secrets.isEmpty)
        XCTAssertEqual(decoded.settings, settings)
    }

    func testDecodePayload_legacyXORSecretBearingPayload_throwsInsecureLegacyPayload() throws {
        // Arrange
        let encoded = try encodeLegacyXORPayload(
            secrets: ["legacyCredential": "credential-value"],
            settings: ["selectedModel": "apple/local/SFSpeechRecognizer"]
        )

        // Act / Assert
        XCTAssertThrowsError(try sut.decodePayload(encoded)) { error in
            guard case ConfigTransferError.insecureLegacyPayload = error else {
                XCTFail("Expected ConfigTransferError.insecureLegacyPayload, got \(error)")
                return
            }
        }
    }

    func testDecodePayload_invalidBase64_throwsInvalidFormat() {
        // Arrange
        let encoded = "not valid base64!!!"

        // Act / Assert
        XCTAssertThrowsError(try sut.decodePayload(encoded)) { error in
            guard case ConfigTransferError.invalidFormat = error else {
                XCTFail("Expected ConfigTransferError.invalidFormat, got \(error)")
                return
            }
        }
    }

    func testDecodePayload_corruptBase64Payload_throwsDecodingFailed() {
        // Arrange
        let encoded = "SGVsbG8gV29ybGQ="

        // Act / Assert
        XCTAssertThrowsError(try sut.decodePayload(encoded)) { error in
            guard case ConfigTransferError.decodingFailed = error else {
                XCTFail("Expected ConfigTransferError.decodingFailed, got \(error)")
                return
            }
        }
    }

    func testValidatePayloadFreshness_recentPayload_returnsTrue() {
        // Arrange
        let payload = ConfigTransferPayload(timestamp: Date(timeIntervalSinceNow: -30))

        // Act
        let isFresh = sut.validatePayloadFreshness(payload, maxAge: 60)

        // Assert
        XCTAssertTrue(isFresh)
    }

    func testValidatePayloadFreshness_expiredPayload_returnsFalse() {
        // Arrange
        let payload = ConfigTransferPayload(timestamp: Date(timeIntervalSinceNow: -660))

        // Act
        let isFresh = sut.validatePayloadFreshness(payload, maxAge: 600)

        // Assert
        XCTAssertFalse(isFresh)
    }

    func testConfigTransferError_descriptions_areUserFacing() {
        // Arrange
        let errors: [ConfigTransferError] = [
            .invalidFormat,
            .payloadExpired,
            .decodingFailed,
            .secretTransferUnsupported,
            .insecureLegacyPayload,
            .unsupportedSettings(["unsupportedSetting"]),
            .unsupportedVersion(3)
        ]

        // Act / Assert
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    private func encodeCurrentPayload(_ payload: ConfigTransferPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload).base64EncodedString()
    }

    private func encodeLegacyXORPayload(
        secrets: [String: String] = [:],
        settings: [String: String] = [:]
    ) throws -> String {
        let payload = ConfigTransferPayload(
            secrets: secrets,
            settings: settings,
            version: 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return xorObfuscate(data).base64EncodedString()
    }

    private func xorObfuscate(_ data: Data) -> Data {
        let key: [UInt8] = [0x53, 0x70, 0x65, 0x61, 0x6B, 0x21]
        var result = Data(count: data.count)
        for (index, byte) in data.enumerated() {
            result[index] = byte ^ key[index % key.count]
        }
        return result
    }
}
