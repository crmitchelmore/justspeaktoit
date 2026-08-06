import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterAPIClientTests: XCTestCase {
    override func tearDown() {
        OpenRouterMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTranscribeFileWithAudioInput_UsesChatCompletionsJSONPayload() async throws {
        let requestObserver = OpenRouterRequestObserver()
        OpenRouterMockURLProtocol.requestHandler = { request in
            await requestObserver.store(request: request)
            return try makeOpenRouterChatResponse(for: request)
        }

        let client = OpenRouterAPIClient(
            apiKeyProvider: { nil },
            session: makeMockSession(),
            apiKeyOverride: "test-openrouter-key"
        )
        let audioURL = try makeAudioFile(extension: "m4a", data: Data("fakeaudiodata".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        _ = try? await client.transcribeFile(
            at: audioURL,
            model: "google/gemini-2.0-flash-001",
            language: "en_GB"
        )

        let capturedRequest = await requestObserver.capturedRequest()
        let capturedBody = await requestObserver.capturedBody()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(capturedBody)

        try assertRequestMetadata(request, body: body)
        try assertAudioInputPayload(body)
    }

    func testBlankAPIKeyOverride_FallsBackToProviderKey() async throws {
        let requestObserver = OpenRouterRequestObserver()
        OpenRouterMockURLProtocol.requestHandler = { request in
            await requestObserver.store(request: request)
            return try makeOpenRouterChatResponse(for: request)
        }

        let client = OpenRouterAPIClient(
            apiKeyProvider: { "stored-openrouter-key" },
            session: makeMockSession(),
            apiKeyOverride: "   "
        )
        let audioURL = try makeAudioFile(extension: "m4a", data: Data("fakeaudiodata".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        _ = try? await client.transcribeFile(
            at: audioURL,
            model: "google/gemini-2.0-flash-001",
            language: "en_GB"
        )

        let capturedRequest = await requestObserver.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer stored-openrouter-key"
        )
    }

    func testTranscribeFileWithOversizedAudio_ThrowsBeforeEncodingPayload() async throws {
        OpenRouterMockURLProtocol.requestHandler = { _ in
            XCTFail("Oversized audio should be rejected before sending a request")
            throw OpenRouterClientError.invalidResponse
        }

        let client = OpenRouterAPIClient(
            apiKeyProvider: { nil },
            session: makeMockSession(),
            apiKeyOverride: "test-openrouter-key",
            maximumInlineAudioBytes: 4
        )
        let audioURL = try makeAudioFile(extension: "m4a", data: Data("fakeaudiodata".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await client.transcribeFile(
                at: audioURL,
                model: "google/gemini-2.0-flash-001",
                language: "en_GB"
            )
            XCTFail("Expected oversized audio to be rejected")
        } catch OpenRouterClientError.audioFileTooLarge(let fileSize, let limit) {
            XCTAssertEqual(fileSize, 13)
            XCTAssertEqual(limit, 4)
        }
    }

    func testSendChatStreaming_ParsesSSEChunksInOrder() async throws {
        let sseBody = """
        data: {"choices":[{"delta":{"role":"assistant","content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":", "}}]}

        : keep-alive comment

        data: {"choices":[{"delta":{"content":"world!"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        OpenRouterMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sseBody.utf8))
        }

        let client = OpenRouterAPIClient(
            apiKeyProvider: { "test-openrouter-key" },
            session: makeMockSession()
        )

        var chunks: [String] = []
        for try await chunk in client.sendChatStreaming(
            systemPrompt: "You are a test.",
            messages: [ChatMessage(role: .user, content: "hi")],
            model: "openai/gpt-4o-mini",
            temperature: 0.2
        ) {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, ["Hello", ", ", "world!"])
        XCTAssertEqual(chunks.joined(), "Hello, world!")
    }

    func testSendChatStreaming_WithoutAPIKey_ThrowsAPIKeyMissing() async {
        let client = OpenRouterAPIClient(
            apiKeyProvider: { nil },
            session: makeMockSession()
        )

        do {
            for try await _ in client.sendChatStreaming(
                systemPrompt: nil,
                messages: [ChatMessage(role: .user, content: "hi")],
                model: "openai/gpt-4o-mini",
                temperature: 0.2
            ) {
                XCTFail("Expected no chunks without an API key")
            }
            XCTFail("Expected apiKeyMissing error")
        } catch OpenRouterClientError.apiKeyMissing {
            // Expected
        } catch {
            XCTFail("Expected apiKeyMissing, got \(error)")
        }
    }

    func testStreamedContent_ParsesDeltaLinesAndIgnoresOtherLines() {
        XCTAssertEqual(
            OpenRouterAPIClient.streamedContent(
                fromSSELine: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#
            ),
            "Hi"
        )
        XCTAssertNil(OpenRouterAPIClient.streamedContent(fromSSELine: ""))
        XCTAssertNil(OpenRouterAPIClient.streamedContent(fromSSELine: ": comment"))
        XCTAssertNil(OpenRouterAPIClient.streamedContent(fromSSELine: "data: [DONE]"))
        XCTAssertNil(
            OpenRouterAPIClient.streamedContent(
                fromSSELine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
            )
        )
        XCTAssertNil(OpenRouterAPIClient.streamedContent(fromSSELine: "data: not-json"))
        XCTAssertTrue(OpenRouterAPIClient.isSSETerminator("data: [DONE]"))
        XCTAssertFalse(OpenRouterAPIClient.isSSETerminator("data: {}"))
    }

    // MARK: - Helpers

    private func assertRequestMetadata(_ request: URLRequest, body: Data) throws {
        let bodyString = String(data: body, encoding: .utf8) ?? ""

        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openrouter-key")
        XCTAssertFalse(bodyString.hasPrefix("--Boundary-"))
    }

    private func assertAudioInputPayload(_ body: Data) throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "google/gemini-2.0-flash-001")
        XCTAssertEqual(json["stream"] as? Bool, false)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let firstMessage = try XCTUnwrap(messages.first)
        XCTAssertEqual(firstMessage["role"] as? String, "user")

        let content = try XCTUnwrap(firstMessage["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertTrue((content.first?["text"] as? String)?.contains("en_GB") == true)

        let audioPart = try XCTUnwrap(content.last)
        XCTAssertEqual(audioPart["type"] as? String, "input_audio")
        let inputAudio = try XCTUnwrap(audioPart["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "m4a")
        XCTAssertEqual(inputAudio["data"] as? String, Data("fakeaudiodata".utf8).base64EncodedString())
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeAudioFile(extension fileExtension: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrouter_audio_\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url)
        return url
    }
}

private func makeOpenRouterChatResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    let json = """
    {
      "choices": [
        {
          "index": 0,
          "finish_reason": "stop",
          "message": {
            "role": "assistant",
            "content": "hello world"
          }
        }
      ]
    }
    """
    return (response, Data(json.utf8))
}

private typealias OpenRouterRequestHandler =
    @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)

private actor OpenRouterRequestObserver {
    private var request: URLRequest?
    private var body: Data?

    func store(request: URLRequest) {
        self.request = request
        body = request.httpBody ?? readBody(from: request.httpBodyStream)
    }

    func capturedRequest() -> URLRequest? {
        request
    }

    func capturedBody() -> Data? {
        body
    }

    private func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data.isEmpty ? nil : data
    }
}

private final class OpenRouterMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: OpenRouterRequestHandler?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("OpenRouterMockURLProtocol.requestHandler was not set")
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
