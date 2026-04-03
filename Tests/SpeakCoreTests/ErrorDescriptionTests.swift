import XCTest
@testable import SpeakCore

final class OpenClawErrorTests: XCTestCase {

    // MARK: - errorDescription

    func testEncodingFailed_errorDescription() {
        let error = OpenClawError.encodingFailed
        XCTAssertEqual(error.errorDescription, "Failed to encode request")
    }

    func testServerError_errorDescription_includesMessage() {
        let error = OpenClawError.serverError("upstream timeout")
        XCTAssertEqual(error.errorDescription, "Server error: upstream timeout")
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

    // MARK: - LocalizedError protocol conformance

    func testEncodingFailed_localizedDescription_isNonNil() {
        let error: Error = OpenClawError.encodingFailed
        XCTAssertNotNil(error.localizedDescription)
    }
}

final class TranscriptionProviderErrorTests: XCTestCase {

    // MARK: - errorDescription

    func testApiKeyMissing_errorDescription() {
        let error = TranscriptionProviderError.apiKeyMissing
        XCTAssertEqual(error.errorDescription, "API key is missing for the transcription provider.")
    }

    func testInvalidResponse_errorDescription() {
        let error = TranscriptionProviderError.invalidResponse
        XCTAssertEqual(error.errorDescription, "Received an invalid response from the transcription service.")
    }

    func testHttpError_errorDescription_includesCodeAndMessage() {
        let error = TranscriptionProviderError.httpError(401, "Unauthorized")
        XCTAssertEqual(error.errorDescription, "HTTP error 401: Unauthorized")
    }

    func testHttpError_errorDescription_500Error() {
        let error = TranscriptionProviderError.httpError(500, "Internal Server Error")
        XCTAssertEqual(error.errorDescription, "HTTP error 500: Internal Server Error")
    }

    func testHttpError_errorDescription_emptyMessage() {
        let error = TranscriptionProviderError.httpError(422, "")
        XCTAssertEqual(error.errorDescription, "HTTP error 422: ")
    }

    // MARK: - LocalizedError protocol conformance

    func testApiKeyMissing_asError_localizedDescriptionIsNonNil() {
        let error: Error = TranscriptionProviderError.apiKeyMissing
        XCTAssertNotNil(error.localizedDescription)
    }
}
