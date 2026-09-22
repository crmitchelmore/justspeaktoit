import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// The dedicated `/api/v1/audio/transcriptions` contract on the shared bounded transport.
final class OpenRouterAudioClientPortableTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = StubURLProtocol.makeSession()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testTranscriptionRequestAndResultPreserveTheDedicatedContract() async throws {
        Self.respond { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), OpenRouterBranding.platformDefault.title)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "HTTP-Referer"), OpenRouterBranding.platformDefault.referer
            )
            let json = try Self.body(request)
            XCTAssertEqual(json["model"] as? String, "openai/whisper-1")
            XCTAssertEqual(json["response_format"] as? String, "json")
            XCTAssertEqual(json["language"] as? String, "en")
            XCTAssertNil(json["messages"])
            let input = try XCTUnwrap(json["input_audio"] as? [String: String])
            XCTAssertEqual(input["format"], "wav")
            XCTAssertEqual(input["data"], Data("RIFF-audio".utf8).base64EncodedString())
            return .json(#"{"text":"hello","usage":{"seconds":4.5,"cost":0.012,"input_tokens":3}}"#)
        }
        let result = try await transcribe(model: "openai/whisper-1", language: "en")
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.duration, 4.5)
        XCTAssertEqual(result.segments.map(\.text), ["hello"])
        XCTAssertEqual(result.segments.first?.endTime, 4.5)
        let cost = try XCTUnwrap(result.cost)
        XCTAssertEqual(NSDecimalNumber(decimal: cost.totalCost).doubleValue, 0.012, accuracy: 1e-9)
        XCTAssertEqual(cost.inputTokens, 3)
        XCTAssertEqual(cost.outputTokens, 0)
        XCTAssertEqual(cost.currency, "USD")
        XCTAssertEqual(result.modelIdentifier, "openrouter/transcription/openai/whisper-1")
        XCTAssertNil(result.rawPayload)
        XCTAssertNil(result.debugInfo)
        XCTAssertEqual(try files().count, 1, "The transcript is decoded in memory; only the input file remains")
    }

    func testBlankLanguageIsOmittedAndEmptyOrUnusableUsageStaysSafe() async throws {
        Self.respond { request in
            XCTAssertNil(try Self.body(request)["language"])
            return .json(#"{"text":""}"#)
        }
        let empty = try await transcribe(fileExtension: "wave", language: "  ")
        XCTAssertEqual(empty.text, "")
        XCTAssertTrue(empty.segments.isEmpty)
        XCTAssertEqual(empty.duration, 0)
        XCTAssertNil(empty.cost)
        Self.respond { _ in .json(#"{"text":"x","usage":{"seconds":-2,"cost":-0.5,"input_tokens":-1}}"#) }
        let unusable = try await transcribe()
        XCTAssertEqual(unusable.duration, 0)
        XCTAssertNil(unusable.cost)
    }

    func testInvalidInputsNeverReachTheNetwork() async throws {
        Self.respond { _ in
            XCTFail("Invalid input should not reach the network")
            return .json(#"{"text":"unexpected"}"#)
        }
        await assertAudioError(.invalidInput) { try await self.transcribe(fileExtension: "aiff") }
        await assertAudioError(.invalidInput) { try await self.transcribe(contents: Data()) }
        await assertAudioError(.invalidInput) { try await self.transcribe(model: "single-component") }
        do {
            _ = try await OpenRouterAudioClient(apiKeyProvider: { " " }, session: session)
                .transcribe(audioFileURL: audioFile(), model: "provider/stt")
            XCTFail("Expected missing key")
        } catch OpenRouterClientError.apiKeyMissing {}
        do {
            _ = try await client(inputLimit: 4).transcribe(audioFileURL: audioFile(), model: "provider/stt")
            XCTFail("Expected input size limit")
        } catch OpenRouterClientError.audioFileTooLarge(let fileSize, let limit) {
            // The bounded read stops one byte past the limit, so that is the size it can report.
            XCTAssertEqual(fileSize, 5)
            XCTAssertEqual(limit, 4)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testProviderAndTransportFailuresMapToFixedMessagesWithoutBodies() async throws {
        Self.respond { _ in OpenRouterAudioFixture(data: Data("secret text and test-key".utf8), status: 401) }
        await assertAudioError(.httpStatus(401)) { try await self.transcribe() } inspect: { error in
            XCTAssertFalse(error.localizedDescription.contains("test-key"))
            XCTAssertFalse(error.localizedDescription.contains("secret text"))
        }
        Self.respond { _ in OpenRouterAudioFixture(data: Data(#"{"text":"mp3"}"#.utf8), contentType: "audio/mpeg") }
        await assertAudioError(.invalidResponse) { try await self.transcribe() }
        Self.respond { _ in .json("not json") }
        await assertAudioError(.invalidResponse) { try await self.transcribe() }
        Self.respond { _ in .json("") }
        await assertAudioError(.invalidResponse) { try await self.transcribe() }
        StubURLProtocol.handler = { request in
            let plain = URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            return .respond(plain, Data())
        }
        await assertAudioError(.invalidResponse) { try await self.transcribe() }
        StubURLProtocol.handler = { _ in .fail(URLError(.timedOut)) }
        await assertAudioError(.timedOut) { try await self.transcribe() }
        StubURLProtocol.handler = { _ in .fail(URLError(.notConnectedToInternet)) }
        await assertAudioError(.transportFailure) { try await self.transcribe() }
        XCTAssertEqual(try files().count, 1)
    }

    func testTranscriptRepliesAreBoundedAtTwoMebibytesInclusive() async throws {
        let limit = 2 * 1024 * 1024
        XCTAssertEqual(OpenRouterAudioClient.maximumTranscriptBytes, limit)
        let declared = expectation(description: "Declared oversize reply cancelled")
        StubURLProtocol.onStopLoading = { declared.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Content-Length": "\(limit + 1)"]
                )!,
                Data(#"{"text":""#.utf8)
            )
        }
        await assertAudioError(.responseTooLarge) { try await self.transcribe() }
        await fulfillment(of: [declared], timeout: 5)

        let streamed = expectation(description: "Streamed oversize reply cancelled")
        StubURLProtocol.onStopLoading = { streamed.fulfill() }
        Self.respond { _ in .json(String(repeating: "a", count: limit + 1)) }
        await assertAudioError(.responseTooLarge) { try await self.transcribe() }
        await fulfillment(of: [streamed], timeout: 5)

        StubURLProtocol.onStopLoading = nil
        let envelope = #"{"text":""}"#.utf8.count
        let padding = String(repeating: "a", count: limit - envelope)
        Self.respond { _ in .json(#"{"text":""# + padding + #""}"#) }
        let atLimit = try await transcribe()
        XCTAssertEqual(atLimit.text.utf8.count, limit - envelope)
    }

    func testCancellationStopsAPendingTranscription() async throws {
        let started = expectation(description: "Response started")
        let stopped = expectation(description: "Transport cancelled")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        Self.respond { _ in
            started.fulfill()
            return OpenRouterAudioFixture(data: Data(#"{"text":"partial"#.utf8), finish: false)
        }
        let audioClient = client()
        let audio = try audioFile()
        let task = Task { try await audioClient.transcribe(audioFileURL: audio, model: "provider/stt") }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await fulfillment(of: [stopped], timeout: 5)
    }

    // MARK: - Helpers

    private func client(inputLimit: Int = 1024) -> OpenRouterAudioClient {
        OpenRouterAudioClient(
            apiKeyProvider: { "test-key" }, session: session,
            maximumInputBytes: inputLimit, temporaryDirectory: directory
        )
    }

    private func transcribe(
        model: String = "provider/stt",
        fileExtension: String = "wav",
        contents: Data = Data("RIFF-audio".utf8),
        language: String? = nil
    ) async throws -> TranscriptionResult {
        try await client().transcribe(
            audioFileURL: audioFile(fileExtension, contents: contents), model: model, language: language
        )
    }

    private func assertAudioError(
        _ expected: OpenRouterAudioError,
        _ operation: () async throws -> TranscriptionResult,
        inspect: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? OpenRouterAudioError, expected, "\(error)")
            inspect(error)
        }
    }

    private func audioFile(_ fileExtension: String = "wav", contents: Data = Data("RIFF-audio".utf8)) throws -> URL {
        let url = directory.appendingPathComponent("input.\(fileExtension)")
        try contents.write(to: url)
        return url
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    /// Installs a fixture-producing handler; the fixture shape is local to these tests.
    private static func respond(_ handler: @escaping @Sendable (URLRequest) throws -> OpenRouterAudioFixture) {
        StubURLProtocol.handler = { request in
            let fixture = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: fixture.status, httpVersion: nil,
                headerFields: ["Content-Type": fixture.contentType]
            )!
            return fixture.finish ? .respond(response, fixture.data) : .respondWithoutFinishing(response, fixture.data)
        }
    }
}

private struct OpenRouterAudioFixture: Sendable {
    let data: Data
    var status = 200
    var contentType = "application/json"
    var finish = true

    static func json(_ text: String) -> Self {
        Self(data: Data(text.utf8))
    }
}
