import XCTest
@testable import SpeakCore

final class GladiaBatchClientTests: XCTestCase {
    private let baseURL = URL(string: "https://gladia.test")!

    // MARK: - Request construction

    func testUploadRequestCarriesTheKeyAndTheAudioPartWithoutBufferingTheRecording() throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let boundary = "Gladia-fixture"
        let file = try BatchTranscriptionJob.writeMultipart(
            fields: [],
            file: .init(field: "audio", filename: "recording.wav", mimeType: "audio/wav", source: audio),
            boundary: boundary)
        defer { BatchTranscriptionJob.discard(file) }
        let body = try XCTUnwrap(String(bytes: Data(contentsOf: file), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"audio\"; filename=\"recording.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testJobBodyPinsSolariaAndOnlySendsALanguageWhenTheUserChoseOne() throws {
        let hinted = GladiaBatchClient.requestBody(audioURL: "https://gladia.test/file/1", language: "fr-CA")
        XCTAssertEqual(hinted["model"] as? String, "solaria-1")
        XCTAssertEqual(hinted["audio_url"] as? String, "https://gladia.test/file/1")
        let hintedLanguages = try XCTUnwrap(hinted["language_config"] as? [String: Any])
        XCTAssertEqual(hintedLanguages["languages"] as? [String], ["fr"])
        XCTAssertEqual(hintedLanguages["code_switching"] as? Bool, false)

        for language in [nil, "  ", "automatic", "AUTO"] as [String?] {
            let automatic = GladiaBatchClient.requestBody(audioURL: "u", language: language)
            let config = try XCTUnwrap(automatic["language_config"] as? [String: Any])
            XCTAssertEqual(config["languages"] as? [String], [])
            XCTAssertEqual(config["code_switching"] as? Bool, true)
        }
    }

    func testUnsupportedContainerIsRejectedBeforeAnyUpload() async {
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try? Data("hello".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        var client = GladiaBatchClient(baseURL: baseURL)
        client.upload = { _, _ in XCTFail("must not upload"); throw CancellationError() }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: text, apiKey: "key", model: GladiaBatchClient.catalogID, language: nil)
        ) { error in
            XCTAssertEqual(
                error as? BatchTranscriptionJobError, .unsupportedAudioFormat("Gladia"))
        }
    }

    func testAMissingKeyAndAForeignModelAreRejectedWithoutNetworkAccess() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        var client = GladiaBatchClient(baseURL: baseURL)
        client.upload = { _, _ in XCTFail("must not upload"); throw CancellationError() }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "  ", model: GladiaBatchClient.catalogID, language: nil)
        ) { XCTAssertEqual($0 as? TranscriptionProviderError, .apiKeyMissing) }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: "gladia/solaria-1-streaming", language: nil)
        ) { XCTAssertEqual($0 as? BatchTranscriptionJobError, .unsupportedModel("Gladia")) }
    }

    // MARK: - Job lifecycle

    func testUploadStartAndPollProduceATranscriptWithUtteranceTimings() async throws {
        let audio = try Self.fixture(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        let recorder = BatchRequestRecorder()
        var client = GladiaBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, file in
            await recorder.record(request)
            XCTAssertNil(request.httpBody)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            return (Data(#"{"audio_url":"https://gladia.test/file/9"}"#.utf8), Self.ok(request))
        }
        client.send = { request in
            await recorder.record(request)
            let count = await recorder.count(forPath: "/v2/pre-recorded/abc")
            if request.httpMethod == "POST" {
                return (
                    Data(#"{"id":"abc","result_url":"https://gladia.test/v2/pre-recorded/abc"}"#.utf8),
                    Self.ok(request)
                )
            }
            if count == 1 { return (Data(#"{"status":"queued"}"#.utf8), Self.ok(request)) }
            if count == 2 { return (Data(#"{"status":"processing"}"#.utf8), Self.ok(request)) }
            return (Data(Self.doneResult.utf8), Self.ok(request))
        }

        let result = try await client.transcribeFile(
            at: audio, apiKey: "gladia-key", model: GladiaBatchClient.catalogID, language: "en-GB")

        XCTAssertEqual(result.text, "Hello there")
        XCTAssertEqual(result.duration, 3.25)
        XCTAssertEqual(result.modelIdentifier, GladiaBatchClient.catalogID)
        XCTAssertEqual(result.segments.map(\.text), ["Hello", "there"])
        XCTAssertEqual(result.segments.first?.startTime, 0.1)
        XCTAssertEqual(try XCTUnwrap(result.confidence), 0.9, accuracy: 0.0001)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.url?.path), [
            "/v2/upload", "/v2/pre-recorded", "/v2/pre-recorded/abc",
            "/v2/pre-recorded/abc", "/v2/pre-recorded/abc"
        ])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-gladia-key") == "gladia-key" })
    }

    func testATerminalErrorStatusFailsImmediatelyRatherThanPollingToTheTimeout() {
        XCTAssertEqual(try? GladiaBatchClient.decodeStatus(Data(#"{"status":"queued"}"#.utf8)), .pending)
        XCTAssertEqual(try? GladiaBatchClient.decodeStatus(Data(#"{"status":"processing"}"#.utf8)), .pending)
        // An unrecognised intermediate state must not abort a job that will succeed.
        XCTAssertEqual(try? GladiaBatchClient.decodeStatus(Data(#"{"status":"uploading"}"#.utf8)), .pending)
        XCTAssertThrowsError(
            try GladiaBatchClient.decodeStatus(Data(#"{"status":"error","error_code":402}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? BatchTranscriptionJobError, .jobFailed("Gladia", "HTTP 402"))
        }
        XCTAssertThrowsError(try GladiaBatchClient.decodeStatus(Data(#"{}"#.utf8)))
    }

    /// Authentication (401, 403) and quota (402, 429) rejections keep the
    /// provider's status and body so the app and the keyboard can render the
    /// provider's own message, on the upload leg and on the polling leg alike.
    func testAuthenticationAndQuotaFailuresKeepTheProviderStatusAndBody() async throws {
        for status in [401, 403, 402, 429] {
            let audio = try Self.fixture(extension: "wav")
            defer { try? FileManager.default.removeItem(at: audio) }
            var client = GladiaBatchClient(baseURL: baseURL)
            client.upload = { request, _ in
                (Data("denied".utf8), Self.response(request, status: status))
            }
            await assertThrowsAsync(
                try await client.transcribeFile(
                    at: audio, apiKey: "key", model: GladiaBatchClient.catalogID, language: nil)
            ) { XCTAssertEqual($0 as? TranscriptionProviderError, .httpError(status, "denied")) }
        }

        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        var client = GladiaBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, _ in
            (Data(#"{"audio_url":"https://gladia.test/file/9"}"#.utf8), Self.ok(request))
        }
        client.send = { request in
            request.httpMethod == "POST"
                ? (Data(#"{"id":"abc"}"#.utf8), Self.ok(request))
                : (Data("quota".utf8), Self.response(request, status: 429))
        }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: GladiaBatchClient.catalogID, language: nil)
        ) { XCTAssertEqual($0 as? TranscriptionProviderError, .httpError(429, "quota")) }
    }

    func testCancellationDuringPollingDeletesTheJobAndSurfacesACancellationError() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let recorder = BatchRequestRecorder()
        var client = GladiaBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, _ in
            (Data(#"{"audio_url":"https://gladia.test/file/9"}"#.utf8), Self.ok(request))
        }
        client.send = { request in
            await recorder.record(request)
            if request.httpMethod == "POST" {
                return (Data(#"{"id":"abc"}"#.utf8), Self.ok(request))
            }
            if request.httpMethod == "DELETE" { return (Data(), Self.ok(request)) }
            throw CancellationError()
        }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: GladiaBatchClient.catalogID, language: nil)
        ) { XCTAssertTrue($0 is CancellationError) }
        let deletes = await recorder.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.map(\.url?.path), ["/v2/pre-recorded/abc"])
    }

    func testACancelledUploadIsReportedAsCancellationAndLeavesTheRecordingIntact() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        var client = GladiaBatchClient(baseURL: baseURL)
        client.upload = { _, _ in throw URLError(.cancelled) }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: GladiaBatchClient.catalogID, language: nil)
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    // MARK: - Responses

    func testASilentRecordingFinalisesAsAnEmptyTranscriptRatherThanAFailure() throws {
        let silent = try GladiaBatchClient.decodeTranscript(
            Data(#"{"result":{"transcription":{"full_transcript":"","utterances":[]}}}"#.utf8))
        XCTAssertEqual(silent.text, "")
        XCTAssertEqual(silent.segments, [])
        XCTAssertEqual(silent.duration, 0)
        XCTAssertNil(silent.confidence)
        XCTAssertThrowsError(try GladiaBatchClient.decodeTranscript(Data(#"{"result":{}}"#.utf8)))
    }

    func testAnOnOriginResultURLFromTheJobResponseWinsOverAConstructedOne() throws {
        let explicit = try GladiaBatchClient.decodeJob(
            Data(#"{"id":"abc","result_url":"https://gladia.test/v2/transcription/abc"}"#.utf8),
            baseURL: baseURL)
        XCTAssertEqual(explicit.resultURL.absoluteString, "https://gladia.test/v2/transcription/abc")
        let derived = try GladiaBatchClient.decodeJob(Data(#"{"id":"abc"}"#.utf8), baseURL: baseURL)
        XCTAssertEqual(derived.resultURL.absoluteString, "https://gladia.test/v2/pre-recorded/abc")
        XCTAssertThrowsError(try GladiaBatchClient.decodeJob(Data(#"{}"#.utf8), baseURL: baseURL))
        XCTAssertThrowsError(try GladiaBatchClient.decodeUpload(Data(#"{"audio_url":""}"#.utf8)))
    }

    func testTheBatchEntryIsInTheBatchPickerAndReusesTheLiveGladiaKey() {
        XCTAssertTrue(ModelCatalog.batchTranscription.contains { $0.id == GladiaBatchClient.catalogID })
        XCTAssertFalse(ModelCatalog.liveTranscription.contains { $0.id == GladiaBatchClient.catalogID })
        XCTAssertEqual(
            ModelCatalog.batchTranscription.first { $0.id == GladiaBatchClient.catalogID }?.displayName,
            "Gladia Solaria-1 (Batch)")
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: GladiaBatchClient.catalogID, purpose: .batchTranscription),
            .apiKey(identifier: "gladia.apiKey", providerName: "Gladia"))
    }

    // MARK: - Fixtures

    private static let doneResult = """
    {"status":"done","result":{"metadata":{"audio_duration":3.25},"transcription":{
     "full_transcript":"Hello there",
     "utterances":[{"start":0.1,"end":0.6,"text":"Hello","confidence":0.95},
                   {"start":0.7,"end":1.2,"text":"there","confidence":0.85}]}}}
    """

    private static func fixture(extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private static func ok(_ request: URLRequest) -> URLResponse { response(request, status: 200) }

    private static func response(_ request: URLRequest, status: Int) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

actor BatchRequestRecorder {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { self.requests.append(request) }
    func count(forPath path: String) -> Int { self.requests.filter { $0.url?.path == path }.count }
}

/// Cancels a task from inside one of its own network doubles. `fire()` waits
/// until the handle is armed, so "cancelled the instant the create response
/// lands" is deterministic rather than a race with the test body.
actor DeferredCanceller {
    private var cancel: (@Sendable () -> Void)?
    private var waiting: CheckedContinuation<Void, Never>?

    func arm(_ cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
        if let waiting = self.waiting {
            self.waiting = nil
            waiting.resume()
        }
    }

    func fire() async {
        if self.cancel == nil {
            await withCheckedContinuation { self.waiting = $0 }
        }
        self.cancel?()
    }
}

func assertThrowsAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
