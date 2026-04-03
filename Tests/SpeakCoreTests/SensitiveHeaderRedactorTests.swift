import XCTest
@testable import SpeakCore

final class SensitiveHeaderRedactorTests: XCTestCase {

    // MARK: - isSensitiveKey

    func testIsSensitiveKey_authorization_isTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("authorization"))
    }

    func testIsSensitiveKey_Authorization_capitalised_isTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("Authorization"))
    }

    func testIsSensitiveKey_apiKey_isTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("api-key"))
    }

    func testIsSensitiveKey_xApiKey_isTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("x-api-key"))
    }

    func testIsSensitiveKey_contentType_isFalse() {
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveKey("content-type"))
    }

    func testIsSensitiveKey_accept_isFalse() {
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveKey("accept"))
    }

    func testIsSensitiveKey_empty_isFalse() {
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveKey(""))
    }

    // MARK: - redactValue

    func testRedactValue_shortValue_returnsRedacted() {
        XCTAssertEqual(SensitiveHeaderRedactor.redactValue("short"), "[REDACTED]")
    }

    func testRedactValue_nineChars_returnsRedacted() {
        XCTAssertEqual(SensitiveHeaderRedactor.redactValue("123456789"), "[REDACTED]")
    }

    func testRedactValue_tenChars_showsPrefixAndSuffix() {
        let result = SensitiveHeaderRedactor.redactValue("abcde12345")
        XCTAssertTrue(result.hasPrefix("abc"), "Expected prefix 'abc', got '\(result)'")
        XCTAssertTrue(result.hasSuffix("2345"), "Expected suffix '2345', got '\(result)'")
        XCTAssertTrue(result.contains("..."), "Expected ellipsis in '\(result)'")
    }

    func testRedactValue_longValue_showsPrefixAndSuffix() {
        let result = SensitiveHeaderRedactor.redactValue("sk-verylongapikeyvalue12345678")
        XCTAssertTrue(result.hasPrefix("sk-"), "Expected 'sk-' prefix, got '\(result)'")
        XCTAssertTrue(result.hasSuffix("5678"), "Expected '5678' suffix, got '\(result)'")
    }

    func testRedactValue_bearerToken_preservesBearerPrefix() {
        let result = SensitiveHeaderRedactor.redactValue("Bearer abcdef1234567890xyz")
        XCTAssertTrue(result.hasPrefix("Bearer "), "Expected 'Bearer ' prefix, got '\(result)'")
        XCTAssertFalse(result.contains("abcdef1234567890xyz"), "Token should be redacted")
    }

    func testRedactValue_bearerShortToken_fullRedact() {
        let result = SensitiveHeaderRedactor.redactValue("Bearer short")
        XCTAssertEqual(result, "Bearer [REDACTED]")
    }

    // MARK: - redactSensitiveHeaders

    func testRedactSensitiveHeaders_nonSensitiveHeaders_passThrough() {
        let headers = ["Content-Type": "application/json", "Accept": "text/plain"]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertEqual(result["Content-Type"], "application/json")
        XCTAssertEqual(result["Accept"], "text/plain")
    }

    func testRedactSensitiveHeaders_authorizationHeader_isRedacted() {
        let headers = ["Authorization": "Bearer sk-toolongapikey123456789"]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertNotEqual(result["Authorization"], "Bearer sk-toolongapikey123456789")
        XCTAssertNotNil(result["Authorization"])
    }

    func testRedactSensitiveHeaders_xApiKeyHeader_isRedacted() {
        let longKey = "abcdefghij1234567890abcdefghij12"  // 32 chars
        let headers = ["x-api-key": longKey]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertNotEqual(result["x-api-key"], longKey)
    }

    func testRedactSensitiveHeaders_openAiStyleValue_isRedactedByValuePattern() {
        let openAIKey = "sk-" + String(repeating: "a", count: 40)
        let headers = ["custom-header": openAIKey]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertNotEqual(result["custom-header"], openAIKey, "sk- pattern should be redacted by value inspection")
    }

    func testRedactSensitiveHeaders_emptyDictionary_returnsEmpty() {
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders([:])
        XCTAssertTrue(result.isEmpty)
    }

    func testRedactSensitiveHeaders_mixedHeaders_onlySensitiveRedacted() {
        let headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer myverylongsecrettoken123456",
            "X-Request-Id": "abc-123"
        ]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertEqual(result["Content-Type"], "application/json")
        XCTAssertEqual(result["X-Request-Id"], "abc-123")
        XCTAssertNotEqual(result["Authorization"], "Bearer myverylongsecrettoken123456")
    }
}
