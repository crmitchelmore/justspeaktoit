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
}

private final class BatchRoutingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handler?(self.request)
        self.client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
    }

    override func stopLoading() {}
}
#endif
