import XCTest
@testable import SpeakCore

final class APIKeyValidationResultTests: XCTestCase {

    // MARK: - Factory methods

    func testSuccess_factory_setsSuccessOutcome() {
        let result = APIKeyValidationResult.success(message: "API key is valid")
        if case .success(let msg) = result.outcome {
            XCTAssertEqual(msg, "API key is valid")
        } else {
            XCTFail("Expected .success outcome")
        }
    }

    func testFailure_factory_setsFailureOutcome() {
        let result = APIKeyValidationResult.failure(message: "Invalid key")
        if case .failure(let msg) = result.outcome {
            XCTAssertEqual(msg, "Invalid key")
        } else {
            XCTFail("Expected .failure outcome")
        }
    }

    func testSuccess_factory_nilDebugByDefault() {
        let result = APIKeyValidationResult.success(message: "OK")
        XCTAssertNil(result.debug)
    }

    func testFailure_factory_nilDebugByDefault() {
        let result = APIKeyValidationResult.failure(message: "Bad")
        XCTAssertNil(result.debug)
    }

    // MARK: - updatingOutcome

    func testUpdatingOutcome_changesOutcome_preservesDebug() {
        let debug = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: "ok",
            errorDescription: nil
        )
        let original = APIKeyValidationResult.success(message: "OK", debug: debug)
        let updated = original.updatingOutcome(.failure(message: "Revoked"))

        if case .failure(let msg) = updated.outcome {
            XCTAssertEqual(msg, "Revoked")
        } else {
            XCTFail("Expected .failure outcome after update")
        }
        XCTAssertNotNil(updated.debug)
        XCTAssertEqual(updated.debug?.url, "https://api.example.com")
    }

    // MARK: - Equatable

    func testOutcome_success_equality() {
        XCTAssertEqual(APIKeyValidationResult.Outcome.success(message: "OK"),
                       APIKeyValidationResult.Outcome.success(message: "OK"))
    }

    func testOutcome_success_inequality_differentMessages() {
        XCTAssertNotEqual(APIKeyValidationResult.Outcome.success(message: "OK"),
                          APIKeyValidationResult.Outcome.success(message: "Different"))
    }

    func testOutcome_successVsFailure_notEqual() {
        XCTAssertNotEqual(APIKeyValidationResult.Outcome.success(message: "x"),
                          APIKeyValidationResult.Outcome.failure(message: "x"))
    }
}

final class APIKeyValidationDebugSnapshotTests: XCTestCase {

    // MARK: - Automatic header redaction

    func testDebugSnapshot_requestHeaders_sensitivesAreRedacted() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.openai.com/v1/models",
            method: "GET",
            requestHeaders: ["Authorization": "Bearer sk-" + String(repeating: "x", count: 40)],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        let authValue = snapshot.requestHeaders["Authorization"] ?? ""
        XCTAssertFalse(authValue.contains(String(repeating: "x", count: 40)),
                       "Raw token should not appear in snapshot: \(authValue)")
    }

    func testDebugSnapshot_responseHeaders_sensitivesAreRedacted() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://example.com",
            method: "POST",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: nil,
            responseHeaders: ["x-api-key": "abcdefghij1234567890abcdefghij12"],
            responseBody: nil,
            errorDescription: nil
        )
        XCTAssertNotEqual(snapshot.responseHeaders["x-api-key"],
                          "abcdefghij1234567890abcdefghij12",
                          "API key in response header should be redacted")
    }

    func testDebugSnapshot_nonSensitiveHeaders_preserved() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Content-Type": "application/json"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: ["Content-Length": "42"],
            responseBody: nil,
            errorDescription: nil
        )
        XCTAssertEqual(snapshot.requestHeaders["Content-Type"], "application/json")
        XCTAssertEqual(snapshot.responseHeaders["Content-Length"], "42")
    }

    func testDebugSnapshot_preservesNonHeaderFields() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.test.com",
            method: "POST",
            requestHeaders: [:],
            requestBody: "{\"model\":\"gpt-4\"}",
            statusCode: 403,
            responseHeaders: [:],
            responseBody: "{\"error\":\"forbidden\"}",
            errorDescription: "Access denied"
        )
        XCTAssertEqual(snapshot.url, "https://api.test.com")
        XCTAssertEqual(snapshot.method, "POST")
        XCTAssertEqual(snapshot.requestBody, "{\"model\":\"gpt-4\"}")
        XCTAssertEqual(snapshot.statusCode, 403)
        XCTAssertEqual(snapshot.responseBody, "{\"error\":\"forbidden\"}")
        XCTAssertEqual(snapshot.errorDescription, "Access denied")
    }
}
