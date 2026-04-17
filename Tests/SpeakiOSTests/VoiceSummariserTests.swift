import Foundation
import XCTest

@testable import SpeakiOSLib

private final class VoiceSummariserMockURLProtocol: URLProtocol {
    private static let handlerQueue = DispatchQueue(label: "VoiceSummariserMockURLProtocol.handler")
    private static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    static func setRequestHandler(
        _ handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
    ) {
        handlerQueue.sync {
            requestHandler = handler
        }
    }

    static func currentRequestHandler() -> (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))? {
        handlerQueue.sync {
            requestHandler
        }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.currentRequestHandler() else {
            XCTFail("VoiceSummariserMockURLProtocol.requestHandler was not set")
            return
        }

        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private func voiceSummariserRequestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        guard readCount > 0 else {
            break
        }
        data.append(buffer, count: readCount)
    }

    return data.isEmpty ? nil : data
}

@MainActor
final class VoiceSummariserTests: XCTestCase {
    private let markdownInput = """
    ## Summary

    - First point
    - Second point
    """

    override func tearDown() {
        VoiceSummariserMockURLProtocol.setRequestHandler(nil)
        super.tearDown()
    }

    func testSummarise_returnsShortPlainTextWithoutCallingAPI() async throws {
        let summariser = VoiceSummariser(session: makeSession())
        let result = try await summariser.summarise("Short plain answer.", apiKey: "test-key")

        XCTAssertEqual(result, "Short plain answer.")
    }

    func testSummarise_sendsExpectedRequestAndTrimsResponse() async throws {
        let expectedUserContent = markdownInput
        VoiceSummariserMockURLProtocol.setRequestHandler { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Just Speak to It iOS")

            let body = try XCTUnwrap(voiceSummariserRequestBody(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "openai/gpt-4o-mini")
            XCTAssertEqual(json["max_tokens"] as? Int, 300)

            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            XCTAssertEqual(messages.last?["role"] as? String, "user")
            XCTAssertEqual(messages.last?["content"] as? String, expectedUserContent)

            let data = Data(
                """
            {
              "choices": [
                {
                  "message": {
                    "content": "  Spoken answer with markdown removed.  "
                  }
                }
              ]
            }
            """.utf8
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        let summariser = VoiceSummariser(session: makeSession())
        let result = try await summariser.summarise(markdownInput, apiKey: "test-key")

        XCTAssertEqual(result, "Spoken answer with markdown removed.")
    }

    func testSummarise_throwsAPIErrorForNonSuccessResponse() async {
        VoiceSummariserMockURLProtocol.setRequestHandler { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("rate limited".utf8))
        }

        let summariser = VoiceSummariser(session: makeSession())

        do {
            _ = try await summariser.summarise(markdownInput, apiKey: "test-key")
            XCTFail("Expected apiError")
        } catch let error as VoiceSummariserError {
            XCTAssertEqual(error.errorDescription, "Summarisation error (429): rate limited")
        } catch {
            XCTFail("Expected VoiceSummariserError, got \(error)")
        }
    }

    func testSummarise_throwsInvalidResponseForMalformedPayload() async {
        VoiceSummariserMockURLProtocol.setRequestHandler { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"choices\":[]}".utf8))
        }

        let summariser = VoiceSummariser(session: makeSession())

        do {
            _ = try await summariser.summarise(markdownInput, apiKey: "test-key")
            XCTFail("Expected invalidResponse")
        } catch let error as VoiceSummariserError {
            switch error {
            case .invalidResponse:
                break
            case .apiError:
                XCTFail("Expected invalidResponse, got apiError")
            }
        } catch {
            XCTFail("Expected VoiceSummariserError, got \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceSummariserMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
