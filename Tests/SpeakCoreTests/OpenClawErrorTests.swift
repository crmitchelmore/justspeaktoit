import XCTest

@testable import SpeakCore

final class OpenClawErrorTests: XCTestCase {

    // MARK: - errorDescription

    func testEncodingFailed_errorDescription() {
        let error = OpenClawError.encodingFailed
        XCTAssertEqual(error.errorDescription, "Failed to encode request")
    }

    func testServerError_errorDescription_containsMessage() {
        let error = OpenClawError.serverError("timeout")
        XCTAssertEqual(error.errorDescription, "Server error: timeout")
    }

    func testServerError_emptyMessage_stillPrefixed() {
        let error = OpenClawError.serverError("")
        XCTAssertEqual(error.errorDescription, "Server error: ")
    }

    func testNotConnected_errorDescription() {
        let error = OpenClawError.notConnected
        XCTAssertEqual(error.errorDescription, "Not connected to OpenClaw gateway")
    }

    func testInvalidResponse_errorDescription() {
        let error = OpenClawError.invalidResponse
        XCTAssertEqual(error.errorDescription, "Invalid response from server")
    }

    // MARK: - LocalizedError conformance

    func testAllCases_haveNonNilDescription() {
        let errors: [OpenClawError] = [
            .encodingFailed,
            .serverError("msg"),
            .notConnected,
            .invalidResponse,
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(
                error.errorDescription?.isEmpty ?? true,
                "\(error) description should not be empty"
            )
        }
    }
}
