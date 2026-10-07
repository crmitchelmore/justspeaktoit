import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest

final class AzureLocalProxyTests: XCTestCase {
    private let token = String(repeating: "a", count: 43)

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testBatchEndpoint_acceptsOnlyExplicitLiteralLoopback() throws {
        XCTAssertEqual(
            try AzureSpeechConfiguration.batchResourceURL(" http://127.0.0.1:8765/ ").port, 8765
        )
        for endpoint in ["http://localhost:8765", "http://127.0.0.2:8765", "http://[::1]:8765",
                         "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536",
                         "http://127.0.0.1:8765/path", "http://user@127.0.0.1:8765",
                         "http://127.0.0.1:8765?key=secret", "http://127.0.0.1:8765#fragment",
                         "http://example.com:8765"] {
            XCTAssertThrowsError(try AzureSpeechConfiguration.batchResourceURL(endpoint), endpoint)
        }
        XCTAssertThrowsError(try AzureSpeechConfiguration.resourceURL("http://127.0.0.1:8765"))
    }

    func testCredentialBoundary_keepsAzureKeysAndLocalTokensOnTheirOwnRoutes() throws {
        let credentials = AzureSpeechConfiguration.proxyCredentialPrefix + token
        let connection = try AzureSpeechConfiguration.batchConnection(
            credentials: credentials, endpoint: "http://127.0.0.1:8765"
        )
        XCTAssertEqual(connection.apiKey, token)
        XCTAssertEqual(connection.origin.host, "127.0.0.1")
        XCTAssertThrowsError(try AzureSpeechConfiguration.batchConnection(
            credentials: "azure-secret:eastus", endpoint: "http://127.0.0.1:8765"
        ))
        for endpoint in ["", "https://demo.cognitiveservices.azure.com"] {
            XCTAssertThrowsError(try AzureSpeechConfiguration.batchConnection(
                credentials: credentials, endpoint: endpoint
            ))
        }
        XCTAssertThrowsError(try AzureSpeechConfiguration(credentials: credentials))
        XCTAssertThrowsError(try AzureSpeechConfiguration.batchConnection(
            credentials: "local-proxy/invalid", endpoint: "http://127.0.0.1:8765"
        ))
        let direct = try AzureSpeechConfiguration.batchConnection(credentials: "key:uksouth", endpoint: "")
        XCTAssertEqual(direct.apiKey, "key")
        XCTAssertEqual(direct.origin.host, "uksouth.api.cognitive.microsoft.com")
    }

    func testRealBatchClient_usesProxyTokenAndPreservesMAIRequest() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let audio = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 0, count: 48_000), sampleRate: 16_000))
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        StubURLProtocol.respond { request in
            let body = StubURLProtocol.body(of: request)
            // Multipart contains binary WAV data as well as text fields.
            // swiftlint:disable:next optional_data_string_conversion
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("MAI-Transcribe-2"))
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
                )),
                Data(#"{"combinedPhrases":[{"text":"Hello proxy."}],"durationMilliseconds":1000}"#.utf8)
            )
        }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let result = try await AzureBatchTranscriptionClient(session: session).transcribeFile(
            at: url, credentials: "local-proxy/" + token, endpoint: "http://127.0.0.1:8765",
            model: AzureTranscriptionModels.mai2, language: "en-GB"
        )
        XCTAssertEqual(result.text, "Hello proxy.")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), token)
        XCTAssertFalse(request.url!.absoluteString.contains(token))
    }

    func testConfiguredProxy_transcribesSyntheticFixtureWithRealClient() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let tokenFile = env["JSTI_AZURE_PROXY_TOKEN_FILE"],
              let fixture = env["JSTI_AZURE_TEST_WAV"],
              let endpoint = env["JSTI_AZURE_TEST_ENDPOINT"] else {
            throw XCTSkip("Requires an explicitly configured local proxy and synthetic WAV.")
        }
        let localToken = try String(contentsOfFile: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for model in [AzureTranscriptionModels.fast, AzureTranscriptionModels.mai2] {
            let result = try await AzureBatchTranscriptionClient().transcribeFile(
                at: URL(fileURLWithPath: fixture), credentials: "local-proxy/" + localToken,
                endpoint: endpoint, model: model, language: "en-GB"
            )
            XCTAssertTrue(result.text.lowercased().contains("quick brown fox"), model)
            XCTAssertTrue(result.text.lowercased().contains("lazy dog"), model)
            XCTAssertGreaterThan(result.duration, 0)
        }
    }
}
