import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Locks the user-visible failure text that an OpenAI batch transcription
/// produces. These descriptions reach the HUD, the history entry and the
/// diagnostics report, so a change here is a change in product behaviour.
final class OpenAITranscriptionProviderErrorTests: XCTestCase {

    func testTranscribeFile_httpFailure_reportsTheStatusCodeAndTheBody() async throws {
        let body = #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#
        OpenAIErrorMockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        defer { OpenAIErrorMockURLProtocol.responseHandler = nil }

        let error = await transcriptionFailure(apiKey: "bad-key")

        XCTAssertEqual(
            error?.localizedDescription,
            "Server responded with status 401: \(body)"
        )
    }

    func testTranscribeFile_serverFailure_keepsTheBodyForDiagnostics() async throws {
        OpenAIErrorMockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("upstream timeout".utf8))
        }
        defer { OpenAIErrorMockURLProtocol.responseHandler = nil }

        let error = await transcriptionFailure(apiKey: "test-key")

        XCTAssertEqual(
            error?.localizedDescription,
            "Server responded with status 500: upstream timeout"
        )
    }

    func testTranscribeFile_nonHTTPResponse_reportsAnInvalidResponse() async throws {
        OpenAIErrorMockURLProtocol.responseHandler = { request in
            let response = URLResponse(
                url: try XCTUnwrap(request.url),
                mimeType: "application/json",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            return (response, Data())
        }
        defer { OpenAIErrorMockURLProtocol.responseHandler = nil }

        let error = await transcriptionFailure(apiKey: "test-key")

        XCTAssertEqual(error?.localizedDescription, "The server returned an invalid response.")
    }

    func testMissingAPIKey_reportsTheEstablishedWording() {
        let error: Error = TranscriptionProviderError.apiKeyMissing
        XCTAssertEqual(error.localizedDescription, "API key is required but not provided.")
    }

    // MARK: - Helpers

    private func transcriptionFailure(apiKey: String) async -> Error? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIErrorMockURLProtocol.self]
        let provider = OpenAITranscriptionProvider(session: URLSession(configuration: configuration))

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai_error_test_\(UUID().uuidString).m4a")
        do {
            try Data("fakeaudiodata".utf8).write(to: audioURL)
        } catch {
            XCTFail("Could not write the test audio file: \(error)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await provider.transcribeFile(
                at: audioURL,
                apiKey: apiKey,
                model: "openai/whisper-1",
                language: nil
            )
            XCTFail("Expected the transcription to fail")
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - Test Infrastructure

private final class OpenAIErrorMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseHandler: (@Sendable (URLRequest) throws -> (URLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.responseHandler else {
            XCTFail("OpenAIErrorMockURLProtocol.responseHandler was not set")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
