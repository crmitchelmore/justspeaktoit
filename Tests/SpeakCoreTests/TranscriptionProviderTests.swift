import XCTest

@testable import SpeakCore

final class TranscriptionProviderErrorTests: XCTestCase {

    // MARK: - apiKeyMissing

    func testAPIKeyMissing_errorDescription_usesTheEstablishedWording() {
        XCTAssertEqual(
            TranscriptionProviderError.apiKeyMissing.errorDescription,
            "API key is required but not provided."
        )
    }

    func testAPIKeyMissing_localizedDescription_matchesTheErrorDescription() {
        let error = TranscriptionProviderError.apiKeyMissing
        XCTAssertEqual(error.localizedDescription, error.errorDescription)
    }

    // MARK: - invalidResponse

    func testInvalidResponse_errorDescription_usesTheEstablishedWording() {
        XCTAssertEqual(
            TranscriptionProviderError.invalidResponse.errorDescription,
            "The server returned an invalid response."
        )
    }

    func testInvalidResponse_localizedDescription_matchesTheErrorDescription() {
        let error = TranscriptionProviderError.invalidResponse
        XCTAssertEqual(error.localizedDescription, error.errorDescription)
    }

    // MARK: - httpError

    func testHTTPError_errorDescription_keepsTheStatusCodeAndTheBody() {
        XCTAssertEqual(
            TranscriptionProviderError.httpError(404, "Not Found").errorDescription,
            "Server responded with status 404: Not Found"
        )
    }

    func testHTTPError_errorDescription_keepsAStructuredBodyVerbatim() {
        let body = #"{"error":{"message":"Invalid API key","type":"invalid_request_error"}}"#
        let description = TranscriptionProviderError.httpError(401, body).errorDescription

        XCTAssertEqual(description, "Server responded with status 401: \(body)")
        XCTAssertTrue(description!.contains("401"))
        XCTAssertTrue(description!.contains("Invalid API key"))
    }

    func testHTTPError_differentCodes_descriptionReflectsTheCode() {
        XCTAssertEqual(
            TranscriptionProviderError.httpError(401, "Unauthorized").errorDescription,
            "Server responded with status 401: Unauthorized"
        )
        XCTAssertEqual(
            TranscriptionProviderError.httpError(503, "Service Unavailable").errorDescription,
            "Server responded with status 503: Service Unavailable"
        )
    }

    func testHTTPError_localizedDescription_matchesTheErrorDescription() {
        let error = TranscriptionProviderError.httpError(500, "Internal Server Error")
        XCTAssertEqual(error.localizedDescription, error.errorDescription)
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

final class LocaleLanguageCodeTests: XCTestCase {
    func testLocaleLanguageCode_stripsRegionAndLowercases() {
        XCTAssertEqual("en_GB".localeLanguageCode, "en")
        XCTAssertEqual("en-US".localeLanguageCode, "en")
        XCTAssertEqual("EN".localeLanguageCode, "en")
    }

    func testLocaleLanguageCode_trimsSurroundingWhitespace() {
        // Untrimmed values used to yield " en", which providers reject.
        XCTAssertEqual(" en-US ".localeLanguageCode, "en")
        XCTAssertEqual("\n en \t".localeLanguageCode, "en")
    }

    func testLocaleLanguageCode_blankInput_isEmpty() {
        XCTAssertEqual("   ".localeLanguageCode, "")
    }
}
