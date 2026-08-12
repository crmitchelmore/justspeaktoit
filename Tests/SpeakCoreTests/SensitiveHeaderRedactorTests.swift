import XCTest

@testable import SpeakCore

final class SensitiveHeaderRedactorTests: XCTestCase {

    // MARK: - isSensitiveKey

    func testIsSensitiveKey_authorization_returnsTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("Authorization"))
    }

    func testIsSensitiveKey_authorization_caseInsensitive() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("AUTHORIZATION"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("authorization"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("AuThOrIzAtIoN"))
    }

    func testIsSensitiveKey_apiKey_returnsTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("api-key"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("x-api-key"))
    }

    func testIsSensitiveKey_vendorSpecificKeys_returnTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("openai-api-key"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("deepgram-api-key"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("anthropic-api-key"))
    }

    func testIsSensitiveKey_tokenKeys_returnTrue() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("token"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("x-auth-token"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("bearer"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("x-access-token"))
    }

    func testIsSensitiveKey_safeHeaders_returnFalse() {
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveKey("Content-Type"))
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveKey("Accept"))
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveKey("User-Agent"))
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveKey("Content-Length"))
    }

    // MARK: - redactValue

    func testRedactValue_longValue_showsFirstAndLast() {
        let key = "sk-abcdefghij1234"
        let redacted = SensitiveHeaderRedactor.redactValue(key)
        XCTAssertTrue(redacted.hasPrefix("sk-"), "Should preserve first 3 chars: got \(redacted)")
        XCTAssertTrue(redacted.hasSuffix("1234"), "Should preserve last 4 chars: got \(redacted)")
        XCTAssertTrue(redacted.contains("..."), "Should contain ellipsis: got \(redacted)")
    }

    func testRedactValue_shortValue_returnsRedactedPlaceholder() {
        XCTAssertEqual(SensitiveHeaderRedactor.redactValue("abc"), "[REDACTED]")
        XCTAssertEqual(SensitiveHeaderRedactor.redactValue("123456789"), "[REDACTED]")
    }

    func testRedactValue_exactlyTenChars_showsFirstAndLast() {
        let value = "1234567890"
        let redacted = SensitiveHeaderRedactor.redactValue(value)
        XCTAssertTrue(redacted.hasPrefix("123"))
        XCTAssertTrue(redacted.hasSuffix("7890"))
    }

    func testRedactValue_bearerToken_preservesBearerPrefix() {
        let value = "Bearer sk-abcdefghijklmnop1234"
        let redacted = SensitiveHeaderRedactor.redactValue(value)
        XCTAssertTrue(redacted.hasPrefix("Bearer "), "Should keep 'Bearer ' prefix: got \(redacted)")
        XCTAssertTrue(redacted.contains("..."), "Should redact the token part: got \(redacted)")
    }

    func testRedactValue_bearerWithShortToken_returnsRedactedToken() {
        let value = "Bearer short"
        let redacted = SensitiveHeaderRedactor.redactValue(value)
        XCTAssertEqual(redacted, "Bearer [REDACTED]")
    }

    // MARK: - redactSensitiveHeaders

    func testRedactSensitiveHeaders_sensitiveKeyRedacted() {
        let headers = ["Authorization": "Bearer my-super-secret-token-xyz", "Content-Type": "application/json"]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertEqual(result["Content-Type"], "application/json", "Non-sensitive headers unchanged")
        let auth = result["Authorization"] ?? ""
        XCTAssertNotEqual(auth, "Bearer my-super-secret-token-xyz", "Authorization should be redacted")
        XCTAssertFalse(auth.contains("my-super-secret"), "Secret value should not appear verbatim")
    }

    func testRedactSensitiveHeaders_emptyDict_returnsEmpty() {
        XCTAssertEqual(SensitiveHeaderRedactor.redactSensitiveHeaders([:]), [:])
    }

    func testRedactSensitiveHeaders_noSensitiveKeys_passesThrough() {
        let headers = ["Content-Type": "text/plain", "Accept": "application/json"]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        // Non-sensitive short values pass through unchanged (not matching API key patterns)
        XCTAssertEqual(result["Content-Type"], "text/plain")
        XCTAssertEqual(result["Accept"], "application/json")
    }

    func testRedactSensitiveHeaders_apiKeyHeader_isRedacted() {
        let key = "sk-testkey1234567890abcdef"
        let headers = ["api-key": key]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertNotEqual(result["api-key"], key)
        XCTAssertNotNil(result["api-key"])
    }

    func testRedactSensitiveHeaders_valueMatchingApiKeyPattern_isRedacted() {
        // A long alphanumeric string (>= 32 chars) triggers isSensitiveValue even for non-standard header names
        let longKey = String(repeating: "a", count: 40)
        let headers = ["x-custom-header": longKey]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertNotEqual(result["x-custom-header"], longKey, "Long alphanumeric values should be redacted")
    }

    func testRedactSensitiveHeaders_caseInsensitiveKeyMatching() {
        let headers = ["X-API-KEY": "my-api-key-123456789012"]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        XCTAssertNotEqual(result["X-API-KEY"], "my-api-key-123456789012")
    }

    func testRedactSensitiveHeaders_openAIStyleKey_redactedByValue() {
        // sk- prefix + long alphanumeric triggers isSensitiveValue
        let apiKey = "sk-ABCDEFGHIJKLMNOPQRSTUVWX"
        let headers = ["Authorization": "Bearer \(apiKey)"]
        let result = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        let auth = result["Authorization"] ?? ""
        XCTAssertFalse(auth.contains(apiKey), "API key must not appear verbatim in redacted output")
    }

    // MARK: - fullyRedactSensitiveHeaders

    func testFullyRedactSensitiveHeaders_keepsNoFragmentOfTheCredential() {
        let apiKey = "sk-ABCDEFGHIJKLMNOPQRSTUVWX"
        let result = SensitiveHeaderRedactor.fullyRedactSensitiveHeaders([
            "Authorization": "Bearer \(apiKey)",
            "x-api-key": "gladia-key-1234567890abcdef",
            "Content-Type": "application/json"
        ])

        XCTAssertEqual(result["Authorization"], "Bearer [REDACTED]")
        XCTAssertEqual(result["x-api-key"], "[REDACTED]")
        XCTAssertEqual(result["Content-Type"], "application/json", "Non-sensitive headers pass through")
    }

    func testFullyRedactSensitiveHeaders_leaksNoPrefixOrSuffix() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let result = SensitiveHeaderRedactor.fullyRedactSensitiveHeaders(["x-api-key": apiKey])
        let redacted = result["x-api-key"] ?? ""

        XCTAssertFalse(redacted.contains(apiKey.prefix(3)))
        XCTAssertFalse(redacted.contains(apiKey.suffix(4)))
    }

    // MARK: - Exact redaction format

    func testRedactValue_exactFormat_first3AndLast4() {
        let apiKey = "sk-1234567890abcdefghijklmnopqrstuvwxyz"
        let redacted = SensitiveHeaderRedactor.redactValue(apiKey)

        XCTAssertEqual(redacted, "sk-...wxyz", "OpenAI-style key should show prefix and suffix")
        XCTAssertFalse(redacted.contains("1234567890"), "Redacted value should not contain middle chars")
    }

    func testRedactValue_trimsWhitespaceBeforeRedacting() {
        let apiKey = "  sk-1234567890abcdefghijklmnopqrstuvwxyz  "
        let redacted = SensitiveHeaderRedactor.redactValue(apiKey)

        XCTAssertEqual(redacted, "sk-...wxyz", "Whitespace should be trimmed before redaction")
    }

    func testRedactSensitiveHeaders_basicCredential_redactedByKey() {
        let headers = [
            "Authorization": "Basic user:pass",  // Redacted because the key is sensitive
            "Content-Type": "text/plain",        // Untouched
            "Custom-Header": "short"             // Untouched (non-sensitive key, short value)
        ]

        let redacted = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)

        XCTAssertEqual(redacted["Authorization"], "Bas...pass", "Authorization should be redacted (sensitive key)")
        XCTAssertEqual(redacted["Content-Type"], "text/plain", "Non-sensitive header should not change")
        XCTAssertEqual(redacted["Custom-Header"], "short", "Short non-pattern value should not change")
    }

    func testRedactSensitiveHeaders_sensitiveKeyWithShortValue_fullyRedacted() {
        // Sensitive keys must be redacted regardless of value length/pattern.
        let headers = [
            "Authorization": "short",
            "x-api-key": "tiny",
            "token": "test123",
            "Content-Type": "application/json"
        ]

        let redacted = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)

        XCTAssertEqual(redacted["Authorization"], "[REDACTED]", "Authorization should be redacted (sensitive key)")
        XCTAssertEqual(redacted["x-api-key"], "[REDACTED]", "x-api-key should be redacted (sensitive key)")
        XCTAssertEqual(redacted["token"], "[REDACTED]", "token should be redacted (sensitive key)")
        XCTAssertEqual(redacted["Content-Type"], "application/json", "Non-sensitive header should not change")
    }

    // MARK: - Integration with APIKeyValidationDebugSnapshot

    func testAPIKeyValidationDebugSnapshotRedactsHeaders() {
        let requestHeaders = [
            "Authorization": "Bearer sk-proj-1234567890abcdefghijklmnopqrstuvwxyz",
            "Content-Type": "application/json"
        ]

        let responseHeaders = [
            "x-api-key": "AbCd1234567890XyZ9876543210MnOpQrSt",
            "Content-Type": "application/json"
        ]

        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com/test",
            method: "POST",
            requestHeaders: requestHeaders,
            requestBody: nil,
            statusCode: 200,
            responseHeaders: responseHeaders,
            responseBody: nil,
            errorDescription: nil
        )

        // Snapshots redact sensitive headers outright: no fragment of the
        // credential is retained, only the auth scheme.
        XCTAssertEqual(
            snapshot.requestHeaders["Authorization"],
            "Bearer [REDACTED]",
            "Request Authorization header should be fully redacted"
        )
        XCTAssertEqual(
            snapshot.responseHeaders["x-api-key"],
            "[REDACTED]",
            "Response x-api-key header should be fully redacted"
        )

        // Verify non-sensitive headers are preserved
        XCTAssertEqual(
            snapshot.requestHeaders["Content-Type"],
            "application/json",
            "Non-sensitive request headers should be preserved"
        )
        XCTAssertEqual(
            snapshot.responseHeaders["Content-Type"],
            "application/json",
            "Non-sensitive response headers should be preserved"
        )

        // Verify original headers are not modified (immutability check)
        XCTAssertEqual(
            requestHeaders["Authorization"],
            "Bearer sk-proj-1234567890abcdefghijklmnopqrstuvwxyz",
            "Original request headers should not be modified"
        )
    }
}
