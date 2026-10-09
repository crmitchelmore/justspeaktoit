import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakApp

@MainActor
final class AzureSharedCredentialValidationTests: XCTestCase {
    private let token = String(repeating: "a", count: 43)

    func testSharedCard_hasTheAzureSpeechNameAndExistingCredential() {
        XCTAssertEqual(TTSProvider.azure.displayName, "Azure Speech")
        XCTAssertEqual(TTSProvider.azure.apiKeyIdentifier, AzureSpeechConfiguration.credentialIdentifier)
        XCTAssertTrue(TTSProvider.azure.sharesTranscriptionCredential)
    }

    func testProxyCredential_checksLocalHealthAndReportsTranscriptionOnly() async throws {
        let result = await validate(
            key: "  local-proxy/\(token)\n", endpoint: "http://127.0.0.1:8765",
            body: #"{"status":"ready","scope":"batch-transcription-and-tts","streaming":"voice-live"}"#
        )

        XCTAssertEqual(result.outcome, .success(
            message: "Local proxy connected for transcription only. "
                + "Azure sign-in and model access are checked when recording."
        ))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8765/health")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), token)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testProxyCredential_rejectedTokenFailsValidation() async {
        let result = await validate(
            key: "local-proxy/\(token)", endpoint: "http://127.0.0.1:8765", status: 401, body: "{}"
        )

        XCTAssertEqual(result.outcome, .failure(
            message: "The local proxy is unavailable or does not support batch transcription."
        ))
    }

    func testProxyCredential_incompatibleHealthFailsValidation() async {
        let result = await validate(
            key: "local-proxy/\(token)", endpoint: "http://127.0.0.1:8765",
            body: #"{"status":"ready","scope":"tts-only"}"#
        )

        XCTAssertEqual(result.outcome, .failure(
            message: "The local proxy is unavailable or does not support batch transcription."
        ))
    }

    func testProxyCredential_remoteEndpointIsRejectedWithoutSendingToken() async {
        let result = await validate(
            key: "local-proxy/\(token)", endpoint: "https://resource.cognitiveservices.azure.com"
        )

        XCTAssertEqual(result.outcome, .failure(
            message: "A local proxy token requires an endpoint such as http://127.0.0.1:8765."
        ))
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testProxyCredential_missingEndpointIsRejectedWithoutSendingToken() async {
        let result = await validate(key: "local-proxy/\(token)", endpoint: "")

        XCTAssertEqual(result.outcome, .failure(
            message: "A local proxy token requires an endpoint such as http://127.0.0.1:8765."
        ))
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testDirectCredential_keepsRegionalVoiceValidation() async throws {
        let result = await validate(
            key: "direct-test-key:uksouth", endpoint: "http://127.0.0.1:8765", body: "[]"
        )

        XCTAssertEqual(result.outcome, .success(
            message: "Azure key and region are valid. Model access depends on your resource."
        ))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://uksouth.tts.speech.microsoft.com/cognitiveservices/voices/list"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "direct-test-key")
    }

    private func validate(
        key: String, endpoint: String, status: Int = 200, body: String = "{}"
    ) async -> APIKeyValidationResult {
        let endpointKey = AzureSpeechConfiguration.endpointDefaultsKey
        let previousEndpoint = UserDefaults.standard.object(forKey: endpointKey)
        UserDefaults.standard.set(endpoint, forKey: endpointKey)
        let suiteName = "AzureSharedCredentialValidationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            UserDefaults.standard.set(previousEndpoint, forKey: endpointKey)
            defaults.removePersistentDomain(forName: suiteName)
        }

        StubURLProtocol.reset()
        StubURLProtocol.respond { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(body.utf8))
        }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }

        let settings = AppSettings(defaults: defaults)
        let storage = SecureAppStorage(
            permissionsManager: PermissionsManager(), appSettings: settings,
            keychainService: "com.justspeaktoit.tests.azure-validation.\(UUID().uuidString)"
        )
        let client = AzureSpeechClient(secureStorage: storage, appSettings: settings, session: session)
        return await client.validateAPIKey(key)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }
}
