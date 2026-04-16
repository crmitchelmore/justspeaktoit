import XCTest

@testable import SpeakCore

final class APIKeyValidationTests: XCTestCase {

    // MARK: - APIKeyValidationDebugSnapshot: auto-redaction

    func testSnapshot_redactsAuthorizationHeader() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com/v1",
            method: "GET",
            requestHeaders: ["Authorization": "Bearer secret-token", "Content-Type": "application/json"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: ["X-Api-Key": "resp-secret"],
            responseBody: nil,
            errorDescription: nil
        )

        XCTAssertNotEqual(snapshot.requestHeaders["Authorization"], "Bearer secret-token",
                          "Authorization header must be redacted")
        XCTAssertEqual(snapshot.requestHeaders["Content-Type"], "application/json",
                       "Non-sensitive headers must be preserved")
    }

    func testSnapshot_redactsResponseHeaders() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com/v1",
            method: "POST",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 401,
            responseHeaders: ["X-Api-Key": "leaked-key", "Content-Type": "text/plain"],
            responseBody: "Unauthorized",
            errorDescription: "Request failed"
        )

        XCTAssertNotEqual(snapshot.responseHeaders["X-Api-Key"], "leaked-key",
                          "X-Api-Key header must be redacted")
        XCTAssertEqual(snapshot.responseHeaders["Content-Type"], "text/plain",
                       "Non-sensitive response headers must be preserved")
    }

    func testSnapshot_preservesNonSensitiveFields() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "DELETE",
            requestHeaders: [:],
            requestBody: "body text",
            statusCode: 204,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: "Deleted"
        )

        XCTAssertEqual(snapshot.url, "https://api.example.com")
        XCTAssertEqual(snapshot.method, "DELETE")
        XCTAssertEqual(snapshot.requestBody, "body text")
        XCTAssertEqual(snapshot.statusCode, 204)
        XCTAssertNil(snapshot.responseBody)
        XCTAssertEqual(snapshot.errorDescription, "Deleted")
    }

    func testSnapshot_emptyHeaders_remainsEmpty() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: nil,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )

        XCTAssertTrue(snapshot.requestHeaders.isEmpty)
        XCTAssertTrue(snapshot.responseHeaders.isEmpty)
        XCTAssertNil(snapshot.statusCode)
        XCTAssertNil(snapshot.errorDescription)
    }

    func testSnapshot_equatable() {
        let s1 = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Accept": "application/json"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: "{}",
            errorDescription: nil
        )
        let s2 = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Accept": "application/json"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: "{}",
            errorDescription: nil
        )
        XCTAssertEqual(s1, s2)
    }

    // MARK: - APIKeyValidationResult: factory methods

    func testSuccess_factory_setsSuccessOutcome() {
        let result = APIKeyValidationResult.success(message: "API key is valid")
        if case .success(let msg) = result.outcome {
            XCTAssertEqual(msg, "API key is valid")
        } else {
            XCTFail("Expected .success outcome")
        }
    }

    func testSuccess_factory_nilDebugByDefault() {
        let result = APIKeyValidationResult.success(message: "OK")
        XCTAssertNil(result.debug)
    }

    func testSuccess_factory_withDebug() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        let result = APIKeyValidationResult.success(message: "OK", debug: snapshot)
        XCTAssertNotNil(result.debug)
    }

    func testFailure_factory_setsFailureOutcome() {
        let result = APIKeyValidationResult.failure(message: "Key rejected")
        if case .failure(let msg) = result.outcome {
            XCTAssertEqual(msg, "Key rejected")
        } else {
            XCTFail("Expected .failure outcome")
        }
    }

    func testFailure_factory_nilDebugByDefault() {
        let result = APIKeyValidationResult.failure(message: "Bad key")
        XCTAssertNil(result.debug)
    }

    // MARK: - APIKeyValidationResult: updatingOutcome

    func testUpdatingOutcome_changesOutcomePreservesDebug() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://example.com",
            method: "POST",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 401,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: "Unauthorized"
        )
        let original = APIKeyValidationResult(outcome: .success(message: "Original"), debug: snapshot)
        let updated = original.updatingOutcome(.failure(message: "Now failing"))

        if case .failure(let msg) = updated.outcome {
            XCTAssertEqual(msg, "Now failing")
        } else {
            XCTFail("Expected .failure after updatingOutcome")
        }
        XCTAssertEqual(updated.debug, snapshot, "debug snapshot must be preserved")
    }

    func testUpdatingOutcome_successToSuccess() {
        let original = APIKeyValidationResult.success(message: "v1")
        let updated = original.updatingOutcome(.success(message: "v2"))
        if case .success(let msg) = updated.outcome {
            XCTAssertEqual(msg, "v2")
        } else {
            XCTFail("Expected .success")
        }
        XCTAssertNil(updated.debug)
    }

    // MARK: - APIKeyValidationResult: Equatable

    func testResult_equatable_sameOutcome() {
        let r1 = APIKeyValidationResult.success(message: "OK")
        let r2 = APIKeyValidationResult.success(message: "OK")
        XCTAssertEqual(r1, r2)
    }

    func testResult_equatable_differentOutcome() {
        let r1 = APIKeyValidationResult.success(message: "OK")
        let r2 = APIKeyValidationResult.failure(message: "Bad")
        XCTAssertNotEqual(r1, r2)
    }
}
