#if os(iOS)
import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakiOSLib

@MainActor
final class BatchProviderRoutingTests: XCTestCase {
    func testPaddedModelsSendCredentialsOnlyToTheirProvider() async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        defer { StubURLProtocol.reset() }

        let cases = [
            (GeminiTranscribeModels.batchCatalogID, "generativelanguage.googleapis.com", "google-test-key"),
            ("google/gemini-2.0-flash-001", "openrouter.ai", "openrouter-test-key"),
            ("openrouter/transcription/openai/gpt-transcribe", "openrouter.ai", "openrouter-test-key")
        ]
        for (model, host, key) in cases {
            let received = expectation(description: "Request reached " + host)
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, host)
                if host == "generativelanguage.googleapis.com" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
                }
                received.fulfill()
                return .fail(URLError(.userAuthenticationRequired))
            }
            do {
                _ = try await IOSBatchTranscriber.transcribeFile(
                    at: audioURL, model: " \n" + model + "\t ", apiKey: key, language: nil, session: session
                )
                XCTFail("The stub rejects the request after checking its destination")
            } catch {
                // The assertions above must run: local validation failure alone
                // must not make this credential-routing regression test pass.
            }
            await fulfillment(of: [received], timeout: 2)
        }
    }

    /// The Cartesia route reports failures in the shared vocabulary the app and
    /// keyboard render (provider name + status), and a silent recording is an
    /// error rather than an empty insert, matching the OpenAI/OpenRouter routes.
    func testCartesiaRouteMapsErrorsAndEmptyTranscriptsLikeSiblingRoutes() async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        defer { StubURLProtocol.reset() }

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.cartesia.ai")
            return .status(401, Data(#"{"error":"bad key"}"#.utf8), url: request.url!)
        }
        do {
            _ = try await IOSBatchTranscriber.transcribeFile(
                at: audioURL, model: CartesiaBatchClient.catalogID, apiKey: "k", language: nil, session: session
            )
            XCTFail("A rejected key must surface as an error")
        } catch let IOSBatchTranscriptionError.httpError(service, status, _) {
            XCTAssertEqual(service, "Cartesia")
            XCTAssertEqual(status, 401)
        }

        StubURLProtocol.handler = { request in
            .status(
                200,
                Data(#"{"type":"transcript","text":"  ","language":"en","duration":0.5,"words":[]}"#.utf8),
                url: request.url!
            )
        }
        do {
            _ = try await IOSBatchTranscriber.transcribeFile(
                at: audioURL, model: CartesiaBatchClient.catalogID, apiKey: "k", language: nil, session: session
            )
            XCTFail("A blank transcript must not be inserted silently")
        } catch IOSBatchTranscriptionError.emptyTranscript {
            // Expected.
        }
    }
}

#endif
