import XCTest

@testable import SpeakCore

final class ConfigTransferManagerTests: XCTestCase {

    /// Cheap key derivation: these tests cover envelope and error handling, not
    /// the cost of PBKDF2, and the production iteration count would add ~1s per
    /// derivation to every run.
    private let sut = ConfigTransferManager(pbkdf2Iterations: 1_000)
    private let code = "A1B2C3D4"

    // MARK: - Round-trip encrypt/decrypt

    func testSharedManager_roundtripsAtProductionCost() throws {
        let manager = ConfigTransferManager.shared
        XCTAssertEqual(manager.pbkdf2Iterations, ConfigTransferManager.productionPBKDF2Iterations)
        XCTAssertGreaterThanOrEqual(manager.pbkdf2Iterations, 210_000, "Key stretching must not be weakened")

        let transfer = try manager.makeTransfer(secrets: ["deepgram.apiKey": "sk-test-12345"], settings: [:])
        let decoded = try manager.decodePayload(transfer.payload, code: transfer.code)
        XCTAssertEqual(decoded.secrets["deepgram.apiKey"], "sk-test-12345")
    }

    func testMakeTransfer_roundtripsWithGeneratedCode() throws {
        let transfer = try sut.makeTransfer(
            secrets: ["deepgram.apiKey": "sk-test-12345"],
            settings: ["selectedModel": "whisper-large"]
        )
        let decoded = try sut.decodePayload(transfer.payload, code: transfer.code)
        XCTAssertEqual(decoded.secrets["deepgram.apiKey"], "sk-test-12345")
        XCTAssertEqual(decoded.settings["selectedModel"], "whisper-large")
        XCTAssertEqual(transfer.formattedCode, ConfigTransferCode.formatted(transfer.code))
    }

    func testGenerateAndDecode_emptyPayload_roundtrips() throws {
        let encoded = try sut.generatePayload(secrets: [:], settings: [:], code: code)
        let decoded = try sut.decodePayload(encoded, code: code)
        XCTAssertTrue(decoded.secrets.isEmpty)
        XCTAssertTrue(decoded.settings.isEmpty)
        XCTAssertEqual(decoded.version, 1)
    }

    func testGenerateAndDecode_withBothSecretsAndSettings_roundtrips() throws {
        let encoded = try sut.generatePayload(
            secrets: ["key1": "value1"],
            settings: ["pref1": "value2"],
            code: code
        )
        let decoded = try sut.decodePayload(encoded, code: code)
        XCTAssertEqual(decoded.secrets["key1"], "value1")
        XCTAssertEqual(decoded.settings["pref1"], "value2")
    }

    func testGenerateAndDecode_unicodeValues_roundtrips() throws {
        let encoded = try sut.generatePayload(secrets: ["apiKey": "tëst-kéy-🔑"], settings: [:], code: code)
        let decoded = try sut.decodePayload(encoded, code: code)
        XCTAssertEqual(decoded.secrets["apiKey"], "tëst-kéy-🔑")
    }

    func testDecodePayload_acceptsCodeWithSeparatorsAndLowercase() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        let decoded = try sut.decodePayload(encoded, code: "a1b2-c3d4")
        XCTAssertEqual(decoded.secrets["k"], "v")
    }

    func testDecodePayload_acceptsCrockfordLookalikeCharacters() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: "01234567")
        // Users typing O for zero and I/l for one should still unlock the payload.
        let decoded = try sut.decodePayload(encoded, code: "OI234567")
        XCTAssertEqual(decoded.secrets["k"], "v")
    }

    // MARK: - Envelope shape

    func testGeneratedPayload_isBase64EnvelopeWithoutPlaintextSecrets() throws {
        let encoded = try sut.generatePayload(secrets: ["apiKey": "supersecret"], settings: [:], code: code)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("supersecret"), "Envelope must not leak plaintext secrets")
        XCTAssertFalse(json.contains(code), "Envelope must not carry the one-time code")
        XCTAssertTrue(json.contains("\"version\""))
        XCTAssertTrue(json.contains("\"createdAt\""))
        XCTAssertTrue(json.contains("\"salt\""))
        XCTAssertTrue(json.contains("\"nonce\""))
        XCTAssertTrue(json.contains("\"ciphertext\""))
    }

    func testGeneratedPayload_usesFreshSaltAndNoncePerExport() throws {
        let first = try sut.decodeEnvelope(
            try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        )
        let second = try sut.decodeEnvelope(
            try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        )
        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
    }

    func testFormat_encryptedPayload_reportsEncrypted() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        XCTAssertEqual(try sut.format(of: encoded), .encrypted)
    }

    // MARK: - Wrong code

    func testDecodePayload_wrongCode_throwsAuthenticationFailed() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        XCTAssertThrowsError(try sut.decodePayload(encoded, code: "Z9Y8X7W6")) { error in
            XCTAssertEqual(error as? ConfigTransferError, .authenticationFailed)
        }
    }

    func testDecodePayload_malformedCode_throwsInvalidCode() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        XCTAssertThrowsError(try sut.decodePayload(encoded, code: "A1B2")) { error in
            XCTAssertEqual(error as? ConfigTransferError, .invalidCode)
        }
        XCTAssertThrowsError(try sut.decodePayload(encoded, code: "A1B2C3D!")) { error in
            XCTAssertEqual(error as? ConfigTransferError, .invalidCode)
        }
    }

    // MARK: - Tampering

    func testDecodePayload_tamperedCiphertext_throwsAuthenticationFailed() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        let envelope = try sut.decodeEnvelope(encoded)
        var ciphertext = envelope.ciphertext
        ciphertext[ciphertext.startIndex] ^= 0xFF
        let tampered = ConfigTransferEnvelope(
            version: envelope.version,
            createdAt: envelope.createdAt,
            salt: envelope.salt,
            nonce: envelope.nonce,
            ciphertext: ciphertext
        )
        XCTAssertThrowsError(try sut.decodePayload(encode(tampered), code: code)) { error in
            XCTAssertEqual(error as? ConfigTransferError, .authenticationFailed)
        }
    }

    func testDecodePayload_refreshedCreatedAt_failsAuthenticationRatherThanImporting() throws {
        // createdAt is authenticated, so an attacker cannot re-date an expired
        // code back into the import window.
        let encoded = try sut.generatePayload(
            secrets: ["k": "v"],
            settings: [:],
            code: code,
            createdAt: Date(timeIntervalSinceNow: -660)
        )
        let envelope = try sut.decodeEnvelope(encoded)
        let rewritten = ConfigTransferEnvelope(
            version: envelope.version,
            createdAt: Date(),
            salt: envelope.salt,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        XCTAssertThrowsError(try sut.decodePayload(encode(rewritten), code: code)) { error in
            XCTAssertEqual(error as? ConfigTransferError, .authenticationFailed)
        }
    }

    // MARK: - Expiry

    func testDecodePayload_expiredPayload_throwsPayloadExpired() throws {
        let createdAt = Date(timeIntervalSinceNow: -660)
        let encoded = try sut.generatePayload(
            secrets: ["k": "v"],
            settings: [:],
            code: code,
            createdAt: createdAt
        )
        XCTAssertThrowsError(try sut.decodePayload(encoded, code: code)) { error in
            XCTAssertEqual(error as? ConfigTransferError, .payloadExpired)
        }
    }

    func testDecodePayload_justInsideExpiryWindow_succeeds() throws {
        let encoded = try sut.generatePayload(
            secrets: ["k": "v"],
            settings: [:],
            code: code,
            createdAt: Date(timeIntervalSinceNow: -540)
        )
        XCTAssertEqual(try sut.decodePayload(encoded, code: code).secrets["k"], "v")
    }

    func testDecodePayload_clockSkewWithinWindow_stillDecodes() throws {
        // Importing device's clock lags the exporting device's by five minutes.
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        let decoded = try sut.decodePayload(encoded, code: code, now: Date(timeIntervalSinceNow: -300))
        XCTAssertEqual(decoded.secrets["k"], "v")
    }

    func testDecodePayload_clockSkewBeyondWindow_throwsPayloadExpired() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        XCTAssertThrowsError(
            try sut.decodePayload(encoded, code: code, now: Date(timeIntervalSinceNow: -900))
        ) { error in
            XCTAssertEqual(error as? ConfigTransferError, .payloadExpired)
        }
    }

    // MARK: - Version handling

    func testDecodePayload_unknownVersion_throwsUnsupportedVersion() throws {
        let encoded = try sut.generatePayload(secrets: ["k": "v"], settings: [:], code: code)
        let envelope = try sut.decodeEnvelope(encoded)
        let future = ConfigTransferEnvelope(
            version: 99,
            createdAt: envelope.createdAt,
            salt: envelope.salt,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        XCTAssertThrowsError(try sut.decodePayload(encode(future), code: code)) { error in
            XCTAssertEqual(error as? ConfigTransferError, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try sut.format(of: encode(future))) { error in
            XCTAssertEqual(error as? ConfigTransferError, .unsupportedVersion(99))
        }
    }

    // MARK: - Helpers

    private func encode(_ envelope: ConfigTransferEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope).base64EncodedString()
    }
}

/// Backwards compatibility, malformed input and one-time code handling, split
/// from the envelope tests to keep each suite a readable size.
final class ConfigTransferCompatibilityTests: XCTestCase {

    private let sut = ConfigTransferManager(pbkdf2Iterations: 1_000)
    private let code = "A1B2C3D4"

    // MARK: - Legacy payloads

    func testFormat_legacyPayload_reportsLegacy() throws {
        XCTAssertEqual(try sut.format(of: try legacyPayload(secrets: ["k": "v"])), .legacy)
    }

    func testDecodeLegacyPayload_stillImports() throws {
        let encoded = try legacyPayload(
            secrets: ["deepgram.apiKey": "legacy-key"],
            settings: ["selectedModel": "nova"]
        )
        let decoded = try sut.decodeLegacyPayload(encoded)
        XCTAssertEqual(decoded.secrets["deepgram.apiKey"], "legacy-key")
        XCTAssertEqual(decoded.settings["selectedModel"], "nova")
        XCTAssertTrue(sut.validatePayloadFreshness(decoded))
    }

    func testDecodePayload_legacyPayloadWithCode_isRejectedAsNotAnEnvelope() throws {
        let legacy = try legacyPayload(secrets: ["k": "v"])
        XCTAssertThrowsError(try sut.decodePayload(legacy, code: code)) { error in
            XCTAssertEqual(error as? ConfigTransferError, .decodingFailed)
        }
    }

    // MARK: - Malformed input

    func testFormat_invalidBase64_throwsInvalidFormat() {
        XCTAssertThrowsError(try sut.format(of: "not valid base64!!!")) { error in
            XCTAssertEqual(error as? ConfigTransferError, .invalidFormat)
        }
    }

    func testFormat_emptyString_throwsInvalidFormat() {
        XCTAssertThrowsError(try sut.format(of: "")) { error in
            XCTAssertEqual(error as? ConfigTransferError, .invalidFormat)
        }
    }

    func testFormat_validBase64ButNotAPayload_throwsDecodingFailed() {
        XCTAssertThrowsError(try sut.format(of: "SGVsbG8gV29ybGQ=")) { error in
            XCTAssertEqual(error as? ConfigTransferError, .decodingFailed)
        }
    }

    // MARK: - Transfer codes

    func testGenerateCode_hasExpectedLengthAndAlphabet() throws {
        let generated = try ConfigTransferCode.generate()
        XCTAssertEqual(generated.count, ConfigTransferCode.length)
        XCTAssertTrue(generated.allSatisfy { ConfigTransferCode.alphabet.contains($0) })
    }

    func testGenerateCode_isNotRepeated() throws {
        let codes = try (0..<32).map { _ in try ConfigTransferCode.generate() }
        XCTAssertEqual(Set(codes).count, codes.count, "Generated codes should be random, not repeated")
    }

    func testFormattedCode_groupsCharacters() {
        XCTAssertEqual(ConfigTransferCode.formatted("A1B2C3D4"), "A1B2-C3D4")
    }

    func testNormalizeCode_rejectsExcludedLetters() {
        XCTAssertThrowsError(try ConfigTransferCode.normalize("UUUUUUUU")) { error in
            XCTAssertEqual(error as? ConfigTransferError, .invalidCode)
        }
    }

    // MARK: - Freshness helper

    func testValidatePayloadFreshness_expiredPayload_returnsFalse() {
        var payload = ConfigTransferPayload()
        payload.timestamp = Date(timeIntervalSinceNow: -660)
        XCTAssertFalse(sut.validatePayloadFreshness(payload))
    }

    func testValidatePayloadFreshness_newPayload_returnsTrue() {
        XCTAssertTrue(sut.validatePayloadFreshness(ConfigTransferPayload()))
    }

    // MARK: - Error descriptions

    func testConfigTransferErrors_allHaveDescriptions() {
        let errors: [ConfigTransferError] = [
            .invalidFormat,
            .payloadExpired,
            .decodingFailed,
            .invalidCode,
            .authenticationFailed,
            .unsupportedVersion(42),
            .encryptionFailed,
            .randomGenerationFailed
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Missing description for \(error)")
        }
    }

    // MARK: - Helpers

    /// Builds a payload in the deprecated pre-encryption format (XOR with the
    /// literal key "Speak!", then base64) to prove imports stay backwards
    /// compatible without depending on production code to produce it.
    private func legacyPayload(
        secrets: [String: String],
        settings: [String: String] = [:]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(ConfigTransferPayload(secrets: secrets, settings: settings))
        let key = Array("Speak!".utf8)
        var obfuscated = Data(count: json.count)
        for (index, byte) in json.enumerated() {
            obfuscated[index] = byte ^ key[index % key.count]
        }
        return obfuscated.base64EncodedString()
    }
}
