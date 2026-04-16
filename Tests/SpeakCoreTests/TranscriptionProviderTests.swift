import XCTest

@testable import SpeakCore

final class TranscriptionProviderErrorTests: XCTestCase {

    // MARK: - apiKeyMissing

    func testAPIKeyMissing_errorDescription_isNonEmpty() {
        let error = TranscriptionProviderError.apiKeyMissing
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testAPIKeyMissing_errorDescription_mentionsAPIKey() {
        let desc = TranscriptionProviderError.apiKeyMissing.errorDescription!
        XCTAssertTrue(
            desc.lowercased().contains("api key"),
            "Description should mention 'API key': \(desc)"
        )
    }

    // MARK: - invalidResponse

    func testInvalidResponse_errorDescription_isNonEmpty() {
        let error = TranscriptionProviderError.invalidResponse
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testInvalidResponse_errorDescription_mentionsResponse() {
        let desc = TranscriptionProviderError.invalidResponse.errorDescription!
        XCTAssertTrue(
            desc.lowercased().contains("response"),
            "Description should mention 'response': \(desc)"
        )
    }

    // MARK: - httpError

    func testHTTPError_errorDescription_containsStatusCode() {
        let error = TranscriptionProviderError.httpError(404, "Not Found")
        let desc = error.errorDescription!
        XCTAssertTrue(desc.contains("404"), "Description should contain status code: \(desc)")
    }

    func testHTTPError_errorDescription_containsMessage() {
        let error = TranscriptionProviderError.httpError(500, "Internal Server Error")
        let desc = error.errorDescription!
        XCTAssertTrue(
            desc.contains("Internal Server Error"),
            "Description should contain message: \(desc)"
        )
    }

    func testHTTPError_differentCodes_descriptionReflectsCode() {
        let error401 = TranscriptionProviderError.httpError(401, "Unauthorized")
        let error503 = TranscriptionProviderError.httpError(503, "Service Unavailable")
        XCTAssertTrue(error401.errorDescription!.contains("401"))
        XCTAssertTrue(error503.errorDescription!.contains("503"))
    }
}

// MARK: - TranscriptionProviderMetadata Tests

final class TranscriptionProviderMetadataTests: XCTestCase {

    func testInit_derivedProperties_apiKeyIdentifier() {
        let meta = TranscriptionProviderMetadata(
            id: "myservice",
            displayName: "My Service"
        )
        XCTAssertEqual(meta.apiKeyIdentifier, "myservice.apiKey")
    }

    func testInit_derivedProperties_apiKeyLabel() {
        let meta = TranscriptionProviderMetadata(
            id: "myservice",
            displayName: "My Service"
        )
        XCTAssertEqual(meta.apiKeyLabel, "My Service API Key")
    }

    func testInit_defaults_appliedCorrectly() {
        let meta = TranscriptionProviderMetadata(
            id: "svc",
            displayName: "Service"
        )
        XCTAssertEqual(meta.systemImage, "network")
        XCTAssertEqual(meta.tintColor, "blue")
        XCTAssertEqual(meta.website, "")
    }

    func testInit_customValues_preserved() {
        let meta = TranscriptionProviderMetadata(
            id: "deepgram",
            displayName: "Deepgram",
            systemImage: "waveform",
            tintColor: "purple",
            website: "https://deepgram.com"
        )
        XCTAssertEqual(meta.id, "deepgram")
        XCTAssertEqual(meta.displayName, "Deepgram")
        XCTAssertEqual(meta.systemImage, "waveform")
        XCTAssertEqual(meta.tintColor, "purple")
        XCTAssertEqual(meta.website, "https://deepgram.com")
    }
}
