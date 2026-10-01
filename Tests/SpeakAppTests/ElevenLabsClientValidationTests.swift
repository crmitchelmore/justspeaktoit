import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp

// MARK: - MockURLProtocol

// MARK: - Tests

@MainActor
final class ElevenLabsClientValidationTests: XCTestCase {

    private func makeMockSession(
        handlers: [@Sendable (String) -> (Int, Data)?]
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Path routing is expressed in the handler rather than in a bespoke
        // URLProtocol subclass (issue #1124).
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            for handler in handlers {
                if let (statusCode, body) = handler(path) {
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!
                    return .respond(response, body)
                }
            }
            return .fail(URLError(.unsupportedURL))
        }
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeSecureStorage() -> SecureAppStorage {
        let settings = AppSettings()
        let permissions = PermissionsManager()
        return SecureAppStorage(
            permissionsManager: permissions,
            appSettings: settings,
            keychainService: "com.justspeaktoit.tests.elevenlabs.validation.\(UUID().uuidString)"
        )
    }

    // Plan requirement: TTS-only restricted key → `/user` 200, `/speech-to-text` 403 → `.invalid`
    func testValidateAPIKey_withTTSOnlyRestrictedKey_returnsInvalid() async {
        let session = makeMockSession(handlers: [
            { path in path.hasSuffix("/user") ? (200, Data()) : nil },
            { path in path.hasSuffix("/speech-to-text") ? (403, Data()) : nil }
        ])
        let client = ElevenLabsClient(secureStorage: makeSecureStorage(), session: session)
        let result = await client.validateAPIKey("test-tts-only-key")
        if case .failure = result.outcome {
            // Expected: TTS-only key lacks Scribe permission
        } else {
            XCTFail("Expected .failure for TTS-only restricted key, got \(result)")
        }
    }

    // Full-access key: `/user` 200, `/speech-to-text` 422 (missing audio) → `.success`
    func testValidateAPIKey_withFullAccessKey_returnsSuccess() async {
        let session = makeMockSession(handlers: [
            { path in path.hasSuffix("/user") ? (200, Data()) : nil },
            { path in path.hasSuffix("/speech-to-text") ? (422, Data()) : nil }
        ])
        let client = ElevenLabsClient(secureStorage: makeSecureStorage(), session: session)
        let result = await client.validateAPIKey("test-full-access-key")
        if case .success = result.outcome {
            // Expected: full-access key has both TTS and Scribe
        } else {
            XCTFail("Expected .success for full-access key, got \(result)")
        }
    }

    // Invalid key: `/user` 401 → `.invalid` without probing Scribe
    func testValidateAPIKey_withInvalidKey_returnsFailureFromUserCheck() async {
        var scribeProbed = false
        let session = makeMockSession(handlers: [
            { path in path.hasSuffix("/user") ? (401, Data()) : nil },
            { path in
                if path.hasSuffix("/speech-to-text") { scribeProbed = true }
                return nil
            }
        ])
        let client = ElevenLabsClient(secureStorage: makeSecureStorage(), session: session)
        let result = await client.validateAPIKey("bad-key")
        if case .failure = result.outcome {
            XCTAssertFalse(scribeProbed, "Scribe endpoint should not be probed for an invalid key")
        } else {
            XCTFail("Expected .failure for invalid key, got \(result)")
        }
    }
}
