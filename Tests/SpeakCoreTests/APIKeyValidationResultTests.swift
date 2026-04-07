import XCTest

@testable import SpeakCore

final class APIKeyValidationResultTests: XCTestCase {

    // MARK: - Factory: success

    func testSuccess_setsOutcomeCorrectly() {
        let result = APIKeyValidationResult.success(message: "Valid key")
        if case .success(let msg) = result.outcome {
            XCTAssertEqual(msg, "Valid key")
        } else {
            XCTFail("Expected .success outcome")
        }
    }

    func testSuccess_debugIsNilByDefault() {
        let result = APIKeyValidationResult.success(message: "OK")
        XCTAssertNil(result.debug)
    }

    func testSuccess_withDebugSnapshot() {
        let snapshot = makeSnapshot()
        let result = APIKeyValidationResult.success(message: "OK", debug: snapshot)
        XCTAssertNotNil(result.debug)
    }

    // MARK: - Factory: failure

    func testFailure_setsOutcomeCorrectly() {
        let result = APIKeyValidationResult.failure(message: "Invalid key")
        if case .failure(let msg) = result.outcome {
            XCTAssertEqual(msg, "Invalid key")
        } else {
            XCTFail("Expected .failure outcome")
        }
    }

    func testFailure_debugIsNilByDefault() {
        let result = APIKeyValidationResult.failure(message: "Bad")
        XCTAssertNil(result.debug)
    }

    func testFailure_withDebugSnapshot() {
        let snapshot = makeSnapshot()
        let result = APIKeyValidationResult.failure(message: "Bad", debug: snapshot)
        XCTAssertNotNil(result.debug)
    }

    // MARK: - updatingOutcome

    func testUpdatingOutcome_successToFailure() {
        let original = APIKeyValidationResult.success(message: "OK")
        let updated = original.updatingOutcome(.failure(message: "Now bad"))
        if case .failure(let msg) = updated.outcome {
            XCTAssertEqual(msg, "Now bad")
        } else {
            XCTFail("Expected .failure after update")
        }
    }

    func testUpdatingOutcome_failureToSuccess() {
        let original = APIKeyValidationResult.failure(message: "Bad")
        let updated = original.updatingOutcome(.success(message: "Now good"))
        if case .success(let msg) = updated.outcome {
            XCTAssertEqual(msg, "Now good")
        } else {
            XCTFail("Expected .success after update")
        }
    }

    func testUpdatingOutcome_preservesDebugSnapshot() {
        let snapshot = makeSnapshot()
        let original = APIKeyValidationResult.success(message: "OK", debug: snapshot)
        let updated = original.updatingOutcome(.failure(message: "Bad"))
        XCTAssertNotNil(updated.debug, "Debug snapshot should be preserved after outcome update")
        XCTAssertEqual(updated.debug?.url, snapshot.url)
    }

    func testUpdatingOutcome_preservesNilDebug() {
        let original = APIKeyValidationResult.success(message: "OK")
        let updated = original.updatingOutcome(.failure(message: "Bad"))
        XCTAssertNil(updated.debug)
    }

    // MARK: - Equatable

    func testEquatable_successEqual() {
        let a = APIKeyValidationResult.success(message: "OK")
        let b = APIKeyValidationResult.success(message: "OK")
        XCTAssertEqual(a, b)
    }

    func testEquatable_successDifferentMessages_notEqual() {
        let a = APIKeyValidationResult.success(message: "OK")
        let b = APIKeyValidationResult.success(message: "Also OK")
        XCTAssertNotEqual(a, b)
    }

    func testEquatable_failureEqual() {
        let a = APIKeyValidationResult.failure(message: "Bad")
        let b = APIKeyValidationResult.failure(message: "Bad")
        XCTAssertEqual(a, b)
    }

    func testEquatable_successVsFailure_notEqual() {
        let a = APIKeyValidationResult.success(message: "msg")
        let b = APIKeyValidationResult.failure(message: "msg")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Outcome Equatable

    func testOutcome_successEqual() {
        let a = APIKeyValidationResult.Outcome.success(message: "yes")
        let b = APIKeyValidationResult.Outcome.success(message: "yes")
        XCTAssertEqual(a, b)
    }

    func testOutcome_failureEqual() {
        let a = APIKeyValidationResult.Outcome.failure(message: "no")
        let b = APIKeyValidationResult.Outcome.failure(message: "no")
        XCTAssertEqual(a, b)
    }

    func testOutcome_differentMessages_notEqual() {
        let a = APIKeyValidationResult.Outcome.success(message: "x")
        let b = APIKeyValidationResult.Outcome.success(message: "y")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - APIKeyValidationDebugSnapshot

    func testSnapshot_headerRedactionApplied() {
        let snapshot = APIKeyValidationDebugSnapshot(
            url: "https://api.example.com",
            method: "GET",
            requestHeaders: ["Authorization": "Bearer sk-1234567890abcdefghijklmnopqrstuvwxyz"],
            requestBody: nil,
            statusCode: 200,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
        // Automatic redaction should be applied (see APIKeyValidationDebugSnapshot.init)
        XCTAssertTrue(
            snapshot.requestHeaders["Authorization"]?.contains("...") == true,
            "Authorization header should be redacted"
        )
    }

    func testSnapshot_equatable_sameValues() {
        let a = makeSnapshot()
        let b = makeSnapshot()
        XCTAssertEqual(a, b)
    }

    // MARK: - Helpers

    private func makeSnapshot() -> APIKeyValidationDebugSnapshot {
        APIKeyValidationDebugSnapshot(
            url: "https://api.test.com",
            method: "POST",
            requestHeaders: ["Content-Type": "application/json"],
            requestBody: nil,
            statusCode: nil,
            responseHeaders: [:],
            responseBody: nil,
            errorDescription: nil
        )
    }
}
