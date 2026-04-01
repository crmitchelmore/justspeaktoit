import XCTest

@testable import SpeakCore

final class TranscriptionProviderErrorTests: XCTestCase {

    // MARK: - apiKeyMissing

    func testApiKeyMissing_errorDescription_returnsExpectedMessage() {
        let error = TranscriptionProviderError.apiKeyMissing
        XCTAssertEqual(
            error.errorDescription,
            "API key is missing for the transcription provider."
        )
    }

    func testApiKeyMissing_localizedDescription_isNonEmpty() {
        let error = TranscriptionProviderError.apiKeyMissing as Error
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    // MARK: - invalidResponse

    func testInvalidResponse_errorDescription_returnsExpectedMessage() {
        let error = TranscriptionProviderError.invalidResponse
        XCTAssertEqual(
            error.errorDescription,
            "Received an invalid response from the transcription service."
        )
    }

    func testInvalidResponse_localizedDescription_isNonEmpty() {
        let error = TranscriptionProviderError.invalidResponse as Error
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    // MARK: - httpError

    func testHttpError_errorDescription_embedsStatusCodeAndMessage() {
        let error = TranscriptionProviderError.httpError(401, "Unauthorized")
        XCTAssertEqual(error.errorDescription, "HTTP error 401: Unauthorized")
    }

    func testHttpError_errorDescription_embedsArbitraryCodeAndMessage() {
        let error = TranscriptionProviderError.httpError(503, "Service Unavailable")
        XCTAssertEqual(error.errorDescription, "HTTP error 503: Service Unavailable")
    }

    func testHttpError_errorDescription_handlesEmptyMessage() {
        let error = TranscriptionProviderError.httpError(500, "")
        XCTAssertEqual(error.errorDescription, "HTTP error 500: ")
    }

    func testHttpError_localizedDescription_isNonEmpty() {
        let error = TranscriptionProviderError.httpError(404, "Not Found") as Error
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    // MARK: - Distinct error descriptions

    func testAllCases_haveDistinctErrorDescriptions() {
        let descriptions = [
            TranscriptionProviderError.apiKeyMissing.errorDescription,
            TranscriptionProviderError.invalidResponse.errorDescription,
            TranscriptionProviderError.httpError(400, "Bad Request").errorDescription,
        ]
        let unique = Set(descriptions.compactMap { $0 })
        XCTAssertEqual(unique.count, 3, "Each error case should produce a distinct description")
    }
}
