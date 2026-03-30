import XCTest

@testable import SpeakCore

final class APIKeyValidationResultTests: XCTestCase {

    // MARK: - APIKeyValidationDebugSnapshot initialisation

    func testInit_requestHeaders_areSensitiveHeadersRedacted() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "POST",
            requestHeaders: [
                "Authorization": "Bearer sk-1234567890abcdefghij",
                "Content-Type": "application/json"
            ],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )

        XCTAssertNotEqual(snapshot.requestHeaders["Authorization"], "Bearer sk-1234567890abcdefghij",
            "Authorization header value should be redacted")
        XCTAssertEqual(snapshot.requestHeaders["Content-Type"], "application/json",
            "Non-sensitive headers should be preserved unchanged")
    }

    func testInit_responseHeaders_areSensitiveHeadersRedacted() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 401,
            responseHeaders: [
                "x-api-key": "secretkey12345",
                "Content-Length": "42"
            ],
            responseBody: "Unauthorized",
            errorDescription: nil
        )

        XCTAssertNotEqual(snapshot.responseHeaders["x-api-key"], "secretkey12345",
            "x-api-key response header should be redacted")
        XCTAssertEqual(snapshot.responseHeaders["Content-Length"], "42",
            "Non-sensitive response headers should be preserved")
    }

    func testInit_nonSensitiveHeadersOnly_allPreserved() {
        let headers = ["Content-Type": "text/plain", "Accept": "application/json"]
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: headers,
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )

        XCTAssertEqual(snapshot.requestHeaders, headers,
            "Non-sensitive headers should pass through unmodified")
    }

    func testInit_emptyHeaders_remainEmpty() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://example.com",
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
    }

    func testInit_allFields_areStoredCorrectly() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com/validate",
            method: "POST",
            requestHeaders: ["Content-Type": "application/json"],
            requestBody: #"{"model":"gpt-4"}"#,
            statusCode: 200,
            responseHeaders: ["Content-Length": "15"],
            responseBody: #"{"ok":true}"#,
            errorDescription: nil
        )

        XCTAssertEqual(snapshot.url, "https://api.example.com/validate")
        XCTAssertEqual(snapshot.method, "POST")
        XCTAssertEqual(snapshot.requestBody, #"{"model":"gpt-4"}"#)
        XCTAssertEqual(snapshot.statusCode, 200)
        XCTAssertEqual(snapshot.responseBody, #"{"ok":true}"#)
        XCTAssertNil(snapshot.errorDescription)
    }

    func testInit_errorDescription_isStored() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: nil,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: "The network connection was lost."
        )

        XCTAssertEqual(snapshot.errorDescription, "The network connection was lost.")
        XCTAssertNil(snapshot.statusCode)
    }

    // MARK: - APIKeyValidationDebugSnapshot Equatable

    func testEquatable_identicalSnapshots_areEqual() {
        let a = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Accept": "application/json"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: "ok",
            errorDescription: nil
        )
        let b = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Accept": "application/json"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: "ok",
            errorDescription: nil
        )

        XCTAssertEqual(a, b)
    }

    func testEquatable_differentStatusCode_notEqual() {
        let a = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        let b = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 401,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )

        XCTAssertNotEqual(a, b)
    }

    // MARK: - APIKeyValidationResult.success factory

    func testSuccessFactory_withoutDebug_setsOutcomeAndNilDebug() {
        let result = APIKeyValidationResult.success(message: "API key is valid")

        if case .success(let msg) = result.outcome {
            XCTAssertEqual(msg, "API key is valid")
        } else {
            XCTFail("Expected .success outcome")
        }
        XCTAssertNil(result.debug)
    }

    func testSuccessFactory_withDebug_setsDebugSnapshot() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
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
        XCTAssertEqual(result.debug, snapshot)
    }

    // MARK: - APIKeyValidationResult.failure factory

    func testFailureFactory_withoutDebug_setsOutcomeAndNilDebug() {
        let result = APIKeyValidationResult.failure(message: "Invalid API key")

        if case .failure(let msg) = result.outcome {
            XCTAssertEqual(msg, "Invalid API key")
        } else {
            XCTFail("Expected .failure outcome")
        }
        XCTAssertNil(result.debug)
    }

    func testFailureFactory_withDebug_setsDebugSnapshot() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "POST",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 401,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: "Unauthorized"
        )
        let result = APIKeyValidationResult.failure(message: "Unauthorized", debug: snapshot)

        XCTAssertNotNil(result.debug)
    }

    // MARK: - APIKeyValidationResult.updatingOutcome

    func testUpdatingOutcome_successToFailure_preservesDebug() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        let original = APIKeyValidationResult.success(message: "OK", debug: snapshot)
        let updated = original.updatingOutcome(.failure(message: "Now failing"))

        if case .failure(let msg) = updated.outcome {
            XCTAssertEqual(msg, "Now failing")
        } else {
            XCTFail("Expected updated outcome to be .failure")
        }
        XCTAssertEqual(updated.debug, snapshot, "Debug snapshot should be preserved when updating outcome")
    }

    func testUpdatingOutcome_failureToSuccess_preservesDebug() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: [:],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        let original = APIKeyValidationResult.failure(message: "Error", debug: snapshot)
        let updated = original.updatingOutcome(.success(message: "Recovered"))

        if case .success(let msg) = updated.outcome {
            XCTAssertEqual(msg, "Recovered")
        } else {
            XCTFail("Expected updated outcome to be .success")
        }
        XCTAssertEqual(updated.debug, snapshot, "Debug snapshot should be preserved when updating outcome")
    }

    func testUpdatingOutcome_nilDebug_remainsNil() {
        let original = APIKeyValidationResult.success(message: "OK")
        let updated = original.updatingOutcome(.failure(message: "Oops"))

        XCTAssertNil(updated.debug, "nil debug should remain nil after updatingOutcome")
    }

    // MARK: - APIKeyValidationResult Equatable

    func testEquatable_sameSuccessOutcomes_areEqual() {
        let a = APIKeyValidationResult.success(message: "Valid")
        let b = APIKeyValidationResult.success(message: "Valid")
        XCTAssertEqual(a, b)
    }

    func testEquatable_differentMessages_notEqual() {
        let a = APIKeyValidationResult.success(message: "OK")
        let b = APIKeyValidationResult.success(message: "All good")
        XCTAssertNotEqual(a, b)
    }

    func testEquatable_successVsFailure_notEqual() {
        let a = APIKeyValidationResult.success(message: "OK")
        let b = APIKeyValidationResult.failure(message: "OK")
        XCTAssertNotEqual(a, b)
    }
}
