import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterAudioClientTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterAudioMockProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        OpenRouterAudioMockProtocol.handler = nil
        OpenRouterAudioMockProtocol.onStop = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testDedicatedTranscription_UsesJSONAndPreservesUsageWithoutDebugBodies() async throws {
        OpenRouterAudioMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
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
        let audio = try audioFile()
        let client = OpenRouterAPIClient(apiKeyProvider: { "test-key" }, session: session)
        let result = try await client.transcribeFile(
            at: audio, model: "openrouter/transcription/openai/whisper-1", language: "en"
        )
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.duration, 4.5)
        XCTAssertEqual(result.cost?.totalCost, Decimal(string: "0.012"))
        XCTAssertEqual(result.cost?.inputTokens, 3)
        XCTAssertEqual(result.modelIdentifier, "openrouter/transcription/openai/whisper-1")
        XCTAssertNil(result.rawPayload)
        XCTAssertNil(result.debugInfo)
    }

    func testTranscription_EmptyTextAndMissingUsageRemainValid() async throws {
        OpenRouterAudioMockProtocol.handler = { request in
            XCTAssertNil(try Self.body(request)["language"])
            return .json(#"{"text":""}"#)
        }
        let result = try await client().transcribe(audioFileURL: audioFile(), model: "provider/stt")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.duration, 0)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.cost)
        XCTAssertEqual(try files().count, 1, "Only the caller's input file should remain")
    }

    func testSpeech_WritesRawMP3AndOmitsUnspecifiedProviderOptions() async throws {
        let mp3 = Data([0x49, 0x44, 0x33, 0, 1, 2])
        OpenRouterAudioMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let json = try Self.body(request)
            XCTAssertEqual(json["model"] as? String, "provider/tts")
            XCTAssertEqual(json["input"] as? String, "Hello")
            XCTAssertEqual(json["response_format"] as? String, "mp3")
            XCTAssertNil(json["voice"])
            XCTAssertNil(json["speed"])
            return OpenRouterAudioFixture(data: mp3)
        }
        let result = try await client().synthesize(text: "Hello", model: "provider/tts", voice: nil)
        XCTAssertEqual(result.audioURL.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: result.audioURL), mp3)
        XCTAssertNil(result.cost)
        XCTAssertEqual(try files(), [result.audioURL])
    }

    func testSpeech_ForwardsExplicitVoiceAndSpeed() async throws {
        OpenRouterAudioMockProtocol.handler = { request in
            let json = try Self.body(request)
            XCTAssertEqual(json["voice"] as? String, "voice/with:punctuation")
            XCTAssertEqual(json["speed"] as? Double, 1.25)
            return OpenRouterAudioFixture(data: Data("ID3".utf8))
        }
        _ = try await client().synthesize(
            text: "Hello", model: "provider/tts", voice: "voice/with:punctuation", speed: 1.25
        )
    }

    func testProviderError_DoesNotExposeBodyOrLeaveFiles() async throws {
        OpenRouterAudioMockProtocol.handler = { _ in
            OpenRouterAudioFixture(data: Data("secret text and test-key".utf8), status: 401)
        }
        do {
            _ = try await client().synthesize(text: "Hello", model: "provider/tts", voice: nil)
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? OpenRouterAudioError, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("test-key"))
            XCTAssertFalse(error.localizedDescription.contains("secret text"))
        }
        XCTAssertTrue(try files().isEmpty)
    }

    func testSpeech_RejectsJSONSuccessAndEmptyAudio() async throws {
        let fixtures = [
            OpenRouterAudioFixture.json(#"{"error":"private text"}"#), .init(data: Data()),
            .init(data: Data("private text".utf8), contentType: "application/octet-stream"),
            .init(data: Data([0, 1, 0, 1]), contentType: "audio/pcm")
        ]
        for fixture in fixtures {
            OpenRouterAudioMockProtocol.handler = { _ in fixture }
            do {
                _ = try await client().synthesize(text: "Hello", model: "provider/tts", voice: nil)
                XCTFail("Expected invalid audio")
            } catch {
                XCTAssertEqual(error as? OpenRouterAudioError, .invalidResponse)
            }
            XCTAssertTrue(try files().isEmpty)
        }
    }

    func testSpeech_RejectsOversizedStreamWithoutContentLengthAndRemovesPartialFile() async throws {
        OpenRouterAudioMockProtocol.handler = { _ in OpenRouterAudioFixture(data: Data(repeating: 7, count: 9)) }
        do {
            _ = try await client(speechLimit: 8).synthesize(text: "Hello", model: "provider/tts", voice: nil)
            XCTFail("Expected bounded download")
        } catch {
            XCTAssertEqual(error as? OpenRouterAudioError, .responseTooLarge)
        }
        XCTAssertTrue(try files().isEmpty)
    }

    func testCancellation_StopsPendingDownloadAndRemovesPartialFile() async throws {
        let started = expectation(description: "Response started")
        let stopped = expectation(description: "Transport cancelled")
        OpenRouterAudioMockProtocol.onStop = { stopped.fulfill() }
        OpenRouterAudioMockProtocol.handler = { _ in
            started.fulfill()
            return OpenRouterAudioFixture(data: Data("ID3".utf8), finish: false)
        }
        let audioClient = client()
        let task = Task { try await audioClient.synthesize(text: "Hello", model: "provider/tts", voice: nil) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(try files().isEmpty)
    }

    func testMissingKeyAndOversizedInput_DoNotSendRequest() async throws {
        OpenRouterAudioMockProtocol.handler = { _ in
            XCTFail("Invalid input should not reach the network")
            return .json(#"{"text":"unexpected"}"#)
        }
        do {
            _ = try await OpenRouterAudioClient(apiKeyProvider: { " " }, session: session)
                .synthesize(text: "Hello", model: "provider/tts", voice: nil)
            XCTFail("Expected missing key")
        } catch OpenRouterClientError.apiKeyMissing { }
        do {
            _ = try await client(inputLimit: 4).transcribe(audioFileURL: audioFile(), model: "provider/stt")
            XCTFail("Expected input size limit")
        } catch OpenRouterClientError.audioFileTooLarge { }
    }

    private func client(inputLimit: Int = 1024, speechLimit: Int = 1024) -> OpenRouterAudioClient {
        OpenRouterAudioClient(
            apiKeyProvider: { "test-key" }, session: session,
            maximumInputBytes: inputLimit, maximumSpeechBytes: speechLimit, temporaryDirectory: directory
        )
    }

    private func audioFile() throws -> URL {
        let url = directory.appendingPathComponent("input.wav")
        try Data("RIFF-audio".utf8).write(to: url)
        return url
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct OpenRouterAudioFixture: Sendable {
    let data: Data
    var status = 200
    var contentType = "audio/mpeg"
    var finish = true

    static func json(_ text: String) -> Self {
        Self(data: Data(text.utf8), contentType: "application/json")
    }
}

private final class OpenRouterAudioMockProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> OpenRouterAudioFixture)?
    nonisolated(unsafe) static var onStop: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let fixture = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: fixture.status, httpVersion: nil,
                headerFields: ["Content-Type": fixture.contentType]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.data)
            if fixture.finish { client?.urlProtocolDidFinishLoading(self) }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { Self.onStop?() }
}
