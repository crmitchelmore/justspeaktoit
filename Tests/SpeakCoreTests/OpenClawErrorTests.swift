import XCTest

@testable import SpeakCore

final class OpenClawErrorTests: XCTestCase {

    // MARK: - errorDescription

    func testEncodingFailed_errorDescription() {
        let error = OpenClawError.encodingFailed
        XCTAssertEqual(error.errorDescription, "Failed to encode request")
    }

    func testServerError_errorDescription_includesMessage() {
        let error = OpenClawError.serverError("timeout")
        XCTAssertEqual(error.errorDescription, "Server error: timeout")
    }

    func testServerError_errorDescription_emptyMessage() {
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

    func testOpenClawError_conformsToLocalizedError() {
        let error: LocalizedError = OpenClawError.notConnected
        XCTAssertNotNil(error.errorDescription)
    }
}
