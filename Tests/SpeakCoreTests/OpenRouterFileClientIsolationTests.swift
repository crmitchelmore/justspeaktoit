import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakCore

final class OpenRouterFileClientIsolationTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testIsolatedFileClientPreservesConfigurationAndKeepsOriginalUsable() async throws {
        StubURLProtocol.respond { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"choices":[{"message":{"content":"hello world"}}]}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 17
        configuration.connectionProxyDictionary = ["HTTPEnable": 0]
        let delegate = ComparisonSessionDelegate()
        let queue = OperationQueue()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let client = OpenRouterAPIClient(
            apiKeyProvider: { nil }, session: session, apiKeyOverride: "test-isolated-key",
            branding: OpenRouterBranding(title: "Comparison fixture", referer: "https://comparison.invalid")
        )
        let isolated = await client.makeIsolatedFileTranscriptionClient()
        defer { isolated.session.invalidateAndCancel() }
        XCTAssertFalse(isolated.session === session)
        XCTAssertEqual(isolated.session.configuration.timeoutIntervalForRequest, 17)
        XCTAssertEqual(isolated.session.configuration.connectionProxyDictionary?["HTTPEnable"] as? Int, 0)
        XCTAssertTrue(isolated.session.delegate === delegate)
        XCTAssertTrue(isolated.session.delegateQueue === queue)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-\(UUID()).m4a")
        try Data("fixture".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let result = try await isolated.client.transcribeFile(
            at: audio, model: "google/gemini-2.0-flash-001", language: nil
        )
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-isolated-key")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Title"), "Comparison fixture")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "HTTP-Referer"),
                       "https://comparison.invalid")
        isolated.session.invalidateAndCancel()
        let originalResult = try await client.transcribeFile(
            at: audio, model: "google/gemini-2.0-flash-001", language: nil
        )
        XCTAssertEqual(originalResult.text, "hello world")
    }

}

private final class ComparisonSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {}
