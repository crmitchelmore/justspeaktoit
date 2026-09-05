#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class BatchProviderRoutingTests: XCTestCase {
    func testPaddedModelsSendCredentialsOnlyToTheirProvider() async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchRoutingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        defer { BatchRoutingURLProtocol.handler = nil }

        let cases = [
            (GeminiTranscribeModels.batchCatalogID, "generativelanguage.googleapis.com", "google-test-key"),
            ("google/gemini-2.0-flash-001", "openrouter.ai", "openrouter-test-key")
        ]
        for (model, host, key) in cases {
            let received = expectation(description: "Request reached " + host)
            BatchRoutingURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, host)
                if host == "generativelanguage.googleapis.com" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
                }
                received.fulfill()
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
        configuration.protocolClasses = [BatchRoutingResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        defer { BatchRoutingResponseURLProtocol.handler = nil }

        BatchRoutingResponseURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.cartesia.ai")
            return (401, Data(#"{"error":"bad key"}"#.utf8))
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

        BatchRoutingResponseURLProtocol.handler = { _ in
            (200, Data(#"{"type":"transcript","text":"  ","language":"en","duration":0.5,"words":[]}"#.utf8))
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

private final class BatchRoutingResponseURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = self.request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(self.request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BatchRoutingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Void)?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handler?(self.request)
        self.client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
    }

    override func stopLoading() {}
}
#endif
