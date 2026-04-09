import XCTest

@testable import SpeakCore

final class APIKeyValidationResultTests: XCTestCase {

    // MARK: - APIKeyValidationResult.Outcome

    func testOutcome_success_isSuccess() {
        let result = APIKeyValidationResult.success(message: "OK")
        guard case .success(let msg) = result.outcome else {
            XCTFail("Expected .success")
            return
        }
        XCTAssertEqual(msg, "OK")
    }

    func testOutcome_failure_isFailure() {
        let result = APIKeyValidationResult.failure(message: "Bad key")
        guard case .failure(let msg) = result.outcome else {
            XCTFail("Expected .failure")
            return
        }
        XCTAssertEqual(msg, "Bad key")
    }

    func testSuccess_noDebug_debugIsNil() {
        let result = APIKeyValidationResult.success(message: "OK")
        XCTAssertNil(result.debug)
    }

    func testFailure_withDebug_debugIsPresent() {
        let snapshot = makeSnapshot(statusCode: 401)
        let result = APIKeyValidationResult.failure(message: "Unauthorized", debug: snapshot)
        XCTAssertNotNil(result.debug)
        XCTAssertEqual(result.debug?.statusCode, 401)
    }

    // MARK: - updatingOutcome

    func testUpdatingOutcome_changesOutcome_preservesDebug() {
        let snapshot = makeSnapshot(statusCode: 200)
        let original = APIKeyValidationResult.success(message: "Initial", debug: snapshot)
        let updated = original.updatingOutcome(.failure(message: "Later failure"))

        guard case .failure(let msg) = updated.outcome else {
            XCTFail("Expected .failure after update")
            return
        }
        XCTAssertEqual(msg, "Later failure")
        // Debug snapshot is preserved
        XCTAssertEqual(updated.debug?.statusCode, 200)
    }

    func testUpdatingOutcome_successToSuccess_updatesMessage() {
        let original = APIKeyValidationResult.success(message: "First")
        let updated = original.updatingOutcome(.success(message: "Second"))
        guard case .success(let msg) = updated.outcome else {
            XCTFail("Expected .success")
            return
        }
        XCTAssertEqual(msg, "Second")
    }

    // MARK: - Equatable

    func testEquatable_sameOutcomeNoDebug_isEqual() {
        let a = APIKeyValidationResult.success(message: "OK")
        let b = APIKeyValidationResult.success(message: "OK")
        XCTAssertEqual(a, b)
    }

    func testEquatable_differentOutcome_isNotEqual() {
        let a = APIKeyValidationResult.success(message: "OK")
        let b = APIKeyValidationResult.failure(message: "OK")
        XCTAssertNotEqual(a, b)
    }

    func testEquatable_differentMessage_isNotEqual() {
        let a = APIKeyValidationResult.success(message: "Valid")
        let b = APIKeyValidationResult.success(message: "OK")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - APIKeyValidationDebugSnapshot header redaction

    func testDebugSnapshot_sensitivHeaders_areRedacted() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Authorization": "Bearer secret123", "Content-Type": "application/json"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        // Authorization header should be redacted
        XCTAssertNotEqual(snapshot.requestHeaders["Authorization"], "Bearer secret123",
                          "Authorization header should be redacted in debug snapshot")
        // Non-sensitive headers are preserved
        XCTAssertEqual(snapshot.requestHeaders["Content-Type"], "application/json")
    }

    func testDebugSnapshot_responseHeaders_areSensitiveRedacted() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "POST",
            requestHeaders: [:],
            requestBody: "{}",
            statusCode: 401,
            responseHeaders: ["X-Api-Key": "leaked-key", "Content-Length": "0"],
            responseBody: "Unauthorized",
            errorDescription: "401 Unauthorized"
        )
        XCTAssertNotEqual(snapshot.responseHeaders["X-Api-Key"], "leaked-key",
                          "API key header should be redacted")
        XCTAssertEqual(snapshot.responseHeaders["Content-Length"], "0")
    }

    func testDebugSnapshot_noSensitiveHeaders_preservesAll() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Accept": "application/json", "User-Agent": "TestApp/1.0"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        XCTAssertEqual(snapshot.requestHeaders["Accept"], "application/json")
        XCTAssertEqual(snapshot.requestHeaders["User-Agent"], "TestApp/1.0")
    }

    func testDebugSnapshot_equatable_sameValues_isEqual() {
        let a = APIKeyValidationDebugSnapshot(
            url: "https://a.com", method: "GET",
            requestHeaders: [:], requestBody: nil,
            statusCode: 200, responseHeaders: [:],
            responseBody: nil, errorDescription: nil
        )
        let b = APIKeyValidationDebugSnapshot(
            url: "https://a.com", method: "GET",
            requestHeaders: [:], requestBody: nil,
            statusCode: 200, responseHeaders: [:],
            responseBody: nil, errorDescription: nil
        )
        XCTAssertEqual(a, b)
    }

    func testDebugSnapshot_equatable_differentURL_isNotEqual() {
        let a = APIKeyValidationDebugSnapshot(
            url: "https://a.com", method: "GET",
            requestHeaders: [:], requestBody: nil,
            statusCode: 200, responseHeaders: [:],
            responseBody: nil, errorDescription: nil
        )
        let b = APIKeyValidationDebugSnapshot(
            url: "https://b.com", method: "GET",
            requestHeaders: [:], requestBody: nil,
            statusCode: 200, responseHeaders: [:],
            responseBody: nil, errorDescription: nil
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helpers

    private func makeSnapshot(statusCode: Int) -> APIKeyValidationDebugSnapshot {
        APIKeyValidationDebugSnapshot(
            url: "https://api.test.com",
            method: "POST",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: statusCode,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
    }
}
