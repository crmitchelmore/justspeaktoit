import XCTest
@testable import SpeakCore

final class SensitiveHeaderRedactorTests: XCTestCase {
    
    // MARK: - Sensitive Key Detection
    
    func testIdentifiesSensitiveHeaderKeys() {
        let sensitiveKeys = [
            "Authorization",
            "authorization",
            "AUTHORIZATION",
            "api-key",
            "API-Key",
            "x-api-key",
            "X-API-KEY",
            "token",
            "Token",
            "x-auth-token",
            "bearer"
        ]
        
        for key in sensitiveKeys {
            XCTAssertTrue(
                SensitiveHeaderRedactor.isSensitiveKey(key),
                "Expected '\(key)' to be identified as sensitive"
            )
        }
    }
    
    func testIdentifiesNonSensitiveHeaderKeys() {
        let nonSensitiveKeys = [
            "Content-Type",
            "Accept",
            "User-Agent",
            "Cache-Control"
        ]
        
        for key in nonSensitiveKeys {
            XCTAssertFalse(
                SensitiveHeaderRedactor.isSensitiveKey(key),
                "Expected '\(key)' to NOT be identified as sensitive"
            )
        }
    }
    
    // MARK: - Value Redaction
    
    func testRedactsOpenAIStyleAPIKey() {
        let apiKey = "sk-1234567890abcdefghijklmnopqrstuvwxyz"
        let redacted = SensitiveHeaderRedactor.redactValue(apiKey)
        
        XCTAssertEqual(redacted, "sk-...wxyz", "OpenAI-style key should show prefix and suffix")
        XCTAssertFalse(redacted.contains("1234567890"), "Redacted value should not contain middle chars")
    }
    
    func testRedactsLongAlphanumericKey() {
        let apiKey = "AbCd1234567890XyZ9876543210MnOpQrSt"
        let redacted = SensitiveHeaderRedactor.redactValue(apiKey)
        
        XCTAssertEqual(redacted, "AbC...rSt", "Long key should show first 3 and last 4 chars")
        XCTAssertTrue(redacted.contains("..."), "Redacted value should contain ellipsis")
    }
    
    func testRedactsBearerToken() {
        let token = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"
        let redacted = SensitiveHeaderRedactor.redactValue(token)
        
        XCTAssertTrue(redacted.hasPrefix("Bearer "), "Bearer prefix should be preserved")
        XCTAssertTrue(redacted.contains("..."), "Token part should be redacted")
        XCTAssertNotEqual(redacted, token, "Value should be redacted")
    }
    
    func testFullyRedactsShortValues() {
        let shortKey = "abc123"
        let redacted = SensitiveHeaderRedactor.redactValue(shortKey)
        
        XCTAssertEqual(redacted, "[REDACTED]", "Short values should be fully redacted")
    }
    
    func testRedactsValueWithWhitespace() {
        let apiKey = "  sk-1234567890abcdefghijklmnopqrstuvwxyz  "
        let redacted = SensitiveHeaderRedactor.redactValue(apiKey)
        
        XCTAssertEqual(redacted, "sk-...wxyz", "Whitespace should be trimmed before redaction")
    }
    
    // MARK: - Header Dictionary Redaction
    
    func testRedactsHeadersDictionary() {
        let headers = [
            "Authorization": "Bearer sk-1234567890abcdefghijklmnopqrstuvwxyz",
            "Content-Type": "application/json",
            "x-api-key": "AbCd1234567890XyZ9876543210MnOpQrSt",
            "User-Agent": "SpeakApp/1.0"
        ]
        
        let redacted = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        
        // Sensitive values should be redacted
        XCTAssertTrue(redacted["Authorization"]?.contains("...") ?? false, "Authorization should be redacted")
        XCTAssertTrue(redacted["x-api-key"]?.contains("...") ?? false, "x-api-key should be redacted")
        
        // Non-sensitive values should remain unchanged
        XCTAssertEqual(redacted["Content-Type"], "application/json", "Content-Type should not be redacted")
        XCTAssertEqual(redacted["User-Agent"], "SpeakApp/1.0", "User-Agent should not be redacted")
    }
    
    func testRedactsEmptyHeadersDictionary() {
        let headers: [String: String] = [:]
        let redacted = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        
        XCTAssertTrue(redacted.isEmpty, "Empty headers should remain empty")
    }
    
    func testRedactsOnlyWhenValueMatchesSensitivePattern() {
        let headers = [
            "Authorization": "Basic user:pass",  // Will be redacted due to long alphanumeric
            "Content-Type": "text/plain",        // Won't be redacted
            "Custom-Header": "short"             // Won't be redacted (too short)
        ]
        
        let redacted = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        
        XCTAssertEqual(redacted["Content-Type"], "text/plain", "Non-sensitive header should not change")
        XCTAssertEqual(redacted["Custom-Header"], "short", "Short non-pattern value should not change")
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
        
        // Verify sensitive headers are redacted
        XCTAssertTrue(
            snapshot.requestHeaders["Authorization"]?.contains("...") ?? false,
            "Request Authorization header should be redacted"
        )
        XCTAssertTrue(
            snapshot.responseHeaders["x-api-key"]?.contains("...") ?? false,
            "Response x-api-key header should be redacted"
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
        XCTAssertFalse(
            requestHeaders["Authorization"]?.contains("...") ?? true,
            "Original request headers should not be modified"
        )
    }
    
    func testMultipleSensitiveHeadersAreAllRedacted() {
        let headers = [
            "Authorization": "Bearer sk-1234567890abcdefghijklmnopqrstuvwxyz",
            "x-api-key": "api_key_1234567890abcdefghijklmnopqrstuvwxyz",
            "token": "token_1234567890abcdefghijklmnopqrstuvwxyz",
            "Content-Type": "application/json"
        ]
        
        let redacted = SensitiveHeaderRedactor.redactSensitiveHeaders(headers)
        
        XCTAssertTrue(redacted["Authorization"]?.contains("...") ?? false)
        XCTAssertTrue(redacted["x-api-key"]?.contains("...") ?? false)
        XCTAssertTrue(redacted["token"]?.contains("...") ?? false)
        XCTAssertEqual(redacted["Content-Type"], "application/json")
    }
}
