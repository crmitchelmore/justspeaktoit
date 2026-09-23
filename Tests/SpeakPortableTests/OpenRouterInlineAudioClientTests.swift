import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// The shared inline-audio chat-completions contract, exercised without any Apple framework.
final class OpenRouterInlineAudioClientTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testPromptOmitsLocaleWhenLanguageIsBlankAndTrimsItOtherwise() async throws {
        let bare = "Transcribe this audio file. Return only the transcript text, with no commentary."
        let located = "Transcribe this audio file using locale en_GB. "
            + "Return only the transcript text, with no commentary."
        let cases: [(String?, String)] = [(nil, bare), ("  \n", bare), (" en_GB ", located)]
        for (language, prompt) in cases {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in .ok(Data(Self.response.utf8), url: request.url!) }
            _ = try await run(client(), "m4a", language: language)
            let content = try Self.content(of: XCTUnwrap(StubURLProtocol.lastRequest))
            XCTAssertEqual(content.first?["text"] as? String, prompt)
        }
    }

    func testAudioFormatFollowsExtensionAliasesAndFallsBackToM4A() async throws {
        let cases = [
            ("wav", "wav"), ("WAVE", "wav"), ("m4b", "m4a"), ("mp3", "mp3"), ("flac", "flac"), ("aac", "aac"),
            ("ogg", "ogg"), ("aiff", "aiff"), ("pcm16", "pcm16"), ("opus", "m4a"), ("", "m4a")
        ]
        for (fileExtension, format) in cases {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in .ok(Data(Self.response.utf8), url: request.url!) }
            _ = try await run(client(), fileExtension)
            let content = try Self.content(of: XCTUnwrap(StubURLProtocol.lastRequest))
            let input = try XCTUnwrap(content.last?["input_audio"] as? [String: String], fileExtension)
            XCTAssertEqual(input["format"], format, fileExtension)
            XCTAssertEqual(input["data"], Data("fakeaudiodata".utf8).base64EncodedString())
        }
    }

    func testRequestCarriesBrandingTrimmedKeyTemperatureZeroAndNoStreaming() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openrouter-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Test host")
            XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://test.invalid")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://test.invalid")
            let body = try Self.json(of: request)
            XCTAssertEqual(body["model"] as? String, "vendor/audio-chat")
            XCTAssertEqual(body["temperature"] as? Double, 0)
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
            return .ok(Data(Self.response.utf8), url: request.url!)
        }
        let branded = client(
            apiKey: " \ntest-openrouter-key\t", branding: .init(title: "Test host", referer: "https://test.invalid")
        )
        let result = try await branded.transcribeFile(at: audioFile("wav"), model: " vendor/audio-chat ", language: nil)
        XCTAssertEqual(result.modelIdentifier, "vendor/audio-chat")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testOversizedAudioAndBlankKeysNeverSendARequest() async throws {
        StubURLProtocol.handler = { _ in
            XCTFail("Nothing should reach the network")
            return .hang
        }
        XCTAssertEqual(OpenRouterInlineAudioTranscriptionClient.defaultMaximumInlineAudioBytes, 50 * 1024 * 1024)
        do {
            _ = try await run(client(limit: 4), "m4a")
            XCTFail("Expected the inline limit")
        } catch OpenRouterClientError.audioFileTooLarge(let fileSize, let limit) {
            XCTAssertEqual(fileSize, 13)
            XCTAssertEqual(limit, 4)
        }
        do {
            _ = try await run(client(apiKey: " \n"), "m4a")
            XCTFail("Expected a missing key")
        } catch OpenRouterClientError.apiKeyMissing {}
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testFirstNonEmptyTrimmedChoiceBecomesTheTranscriptWithoutCost() async throws {
        let body = #"""
        {"choices":[{"message":{"content":"  \n"}},{"message":{"content":"  hello world \n"}},
         {"message":{"content":"ignored"}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}
        """#
        StubURLProtocol.handler = { request in .ok(Data(body.utf8), url: request.url!) }
        let result = try await run(client())
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.segments.map(\.text), ["hello world"])
        XCTAssertEqual(result.duration, 3)
        XCTAssertEqual(result.segments.first?.endTime, 3)
        XCTAssertNil(result.cost)
        XCTAssertNil(result.confidence)
        XCTAssertNil(result.debugInfo)
        XCTAssertEqual(result.rawPayload, body)
    }

    func testEmptyChoicesNonHTTPFailureStatusesAndMalformedJSONAreReported() async throws {
        StubURLProtocol.handler = { request in
            .ok(Data(#"{"choices":[{"message":{"content":" "}},{"message":null}]}"#.utf8), url: request.url!)
        }
        await assertFailure { error in
            guard case OpenRouterClientError.invalidResponse = error else { return XCTFail("\(error)") }
        }
        StubURLProtocol.handler = { request in
            let plain = URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            return .respond(plain, Data())
        }
        await assertFailure { error in
            guard case OpenRouterClientError.invalidResponse = error else { return XCTFail("\(error)") }
        }
        StubURLProtocol.handler = { request in .status(429, Data("slow down".utf8), url: request.url!) }
        await assertFailure { error in
            guard case OpenRouterClientError.httpStatus(let status, let body) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(status, 429)
            XCTAssertEqual(body, "slow down")
        }
        StubURLProtocol.handler = { request in .ok(Data("not json".utf8), url: request.url!) }
        await assertFailure { error in XCTAssertTrue(error is DecodingError, "\(error)") }
    }

    func testDurationEnrichmentNeverDiscardsTheTranscript() async throws {
        StubURLProtocol.handler = { request in .ok(Data(Self.response.utf8), url: request.url!) }
        for reported in [Double.nan, -1, .infinity, 0] {
            let result = try await run(client(duration: { _ in reported }))
            XCTAssertEqual(result.text, "hello world")
            XCTAssertEqual(result.duration, 0, "\(reported)")
            XCTAssertEqual(result.segments.first?.endTime, 0, "\(reported)")
        }
        let result = try await run(client(duration: { _ in 2.5 }))
        XCTAssertEqual(result.duration, 2.5)
        XCTAssertEqual(result.segments.first?.endTime, 2.5)
    }

    func testCancellationStopsAnInFlightRequestAndPreCancelledTasksNeverStart() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request stopped")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let audio = try audioFile("wav")
        let inFlight = client()
        let task = Task { try await inFlight.transcribeFile(at: audio, model: "vendor/audio-chat", language: nil) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)

        StubURLProtocol.resetRecordedRequests()
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await inFlight.transcribeFile(at: audio, model: "vendor/audio-chat", language: nil)
        }
        do {
            _ = try await preCancelled.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    // MARK: - Helpers

    private static let response = #"{"choices":[{"message":{"role":"assistant","content":"hello world"}}]}"#

    private func client(
        apiKey: String = "test-openrouter-key",
        limit: Int64 = OpenRouterInlineAudioTranscriptionClient.defaultMaximumInlineAudioBytes,
        branding: OpenRouterBranding = .platformDefault,
        duration: @escaping @Sendable (URL) async -> TimeInterval = { _ in 3 }
    ) -> OpenRouterInlineAudioTranscriptionClient {
        OpenRouterInlineAudioTranscriptionClient(
            apiKey: apiKey, session: StubURLProtocol.makeSession(), maximumInlineAudioBytes: limit,
            branding: branding, durationResolver: duration
        )
    }

    private func run(
        _ client: OpenRouterInlineAudioTranscriptionClient, _ fileExtension: String = "wav", language: String? = nil
    ) async throws -> TranscriptionResult {
        try await client.transcribeFile(at: audioFile(fileExtension), model: "vendor/audio-chat", language: language)
    }

    private func assertFailure(_ check: (Error) -> Void) async {
        do {
            _ = try await run(client())
            XCTFail("Expected a failure")
        } catch {
            check(error)
        }
    }

    private func audioFile(_ fileExtension: String) throws -> URL {
        let name = fileExtension.isEmpty ? UUID().uuidString : UUID().uuidString + "." + fileExtension
        let url = directory.appendingPathComponent(name)
        try Data("fakeaudiodata".utf8).write(to: url)
        return url
    }

    private static func json(of request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private static func content(of request: URLRequest) throws -> [[String: Any]] {
        let messages = try XCTUnwrap(json(of: request)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "input_audio"])
        return content
    }
}
