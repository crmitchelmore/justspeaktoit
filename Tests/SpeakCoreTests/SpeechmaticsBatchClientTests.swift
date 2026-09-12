import XCTest
@testable import SpeakCore

final class SpeechmaticsBatchClientTests: XCTestCase {
    private let baseURL = URL(string: "https://speechmatics.test")!

    // MARK: - Request construction

    func testConfigSelectsTheTierAndFallsBackToLanguageIdentification() throws {
        let enhanced = try SpeechmaticsBatchClient.configJSON(
            model: SpeechmaticsBatchClient.enhancedCatalogID, language: "fr-CA")
        XCTAssertTrue(enhanced.contains("\"operating_point\":\"enhanced\""))
        XCTAssertTrue(enhanced.contains("\"language\":\"fr\""))
        XCTAssertTrue(enhanced.contains("\"type\":\"transcription\""))

        let standard = try SpeechmaticsBatchClient.configJSON(
            model: SpeechmaticsBatchClient.standardCatalogID, language: nil)
        XCTAssertTrue(standard.contains("\"operating_point\":\"standard\""))
        XCTAssertTrue(standard.contains("\"language\":\"auto\""))
        for language in ["  ", "automatic", "AUTO"] {
            let automatic = try SpeechmaticsBatchClient.configJSON(
                model: SpeechmaticsBatchClient.enhancedCatalogID, language: language)
            XCTAssertTrue(automatic.contains("\"language\":\"auto\""))
        }
    }

    func testAMissingKeyAndAForeignModelAreRejectedWithoutNetworkAccess() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        var client = SpeechmaticsBatchClient(baseURL: baseURL)
        client.upload = { _, _ in XCTFail("must not upload"); throw CancellationError() }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: " ", model: SpeechmaticsBatchClient.enhancedCatalogID, language: nil)
        ) { XCTAssertEqual($0 as? TranscriptionProviderError, .apiKeyMissing) }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: "speechmatics/enhanced-streaming", language: nil)
        ) { XCTAssertEqual($0 as? BatchTranscriptionJobError, .unsupportedModel("Speechmatics")) }

        let text = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: text, apiKey: "key", model: SpeechmaticsBatchClient.standardCatalogID, language: nil)
        ) { XCTAssertEqual($0 as? BatchTranscriptionJobError, .unsupportedAudioFormat("Speechmatics")) }
    }

    // MARK: - Job lifecycle

    func testCreatePollAndFetchProduceATranscriptWithWordTimings() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let recorder = BatchRequestRecorder()
        var client = SpeechmaticsBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, file in
            await recorder.record(request)
            XCTAssertNil(request.httpBody)
            let body = try XCTUnwrap(String(bytes: Data(contentsOf: file), encoding: .utf8))
            XCTAssertTrue(body.contains("name=\"config\""))
            XCTAssertTrue(body.contains("name=\"data_file\"; filename=\"recording.wav\""))
            return (Data(#"{"id":"job-7"}"#.utf8), Self.ok(request))
        }
        client.send = { request in
            await recorder.record(request)
            if request.url?.path.hasSuffix("/transcript") == true {
                return (Data(Self.transcript.utf8), Self.ok(request))
            }
            let polls = await recorder.count(forPath: "/v2/jobs/job-7")
            let status = polls == 1 ? #"{"job":{"status":"running"}}"# : #"{"job":{"status":"done"}}"#
            return (Data(status.utf8), Self.ok(request))
        }

        let result = try await client.transcribeFile(
            at: audio, apiKey: "sm-key", model: SpeechmaticsBatchClient.enhancedCatalogID, language: "en")

        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.duration, 4.5)
        XCTAssertEqual(result.modelIdentifier, SpeechmaticsBatchClient.enhancedCatalogID)
        XCTAssertEqual(result.segments.map(\.text), ["Hello", "there"])
        XCTAssertEqual(result.segments.last?.endTime, 1.2)
        XCTAssertEqual(try XCTUnwrap(result.confidence), 0.9, accuracy: 0.0001)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.url?.path), [
            "/v2/jobs", "/v2/jobs/job-7", "/v2/jobs/job-7", "/v2/jobs/job-7/transcript"
        ])
        XCTAssertEqual(requests.last?.url?.query, "format=json-v2")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sm-key" })
    }

    func testTerminalJobStatesFailImmediatelyAndUnknownStatesKeepPolling() {
        XCTAssertEqual(
            try? SpeechmaticsBatchClient.decodeStatus(Data(#"{"job":{"status":"running"}}"#.utf8)), .pending)
        XCTAssertEqual(
            try? SpeechmaticsBatchClient.decodeStatus(Data(#"{"job":{"status":"queued"}}"#.utf8)), .pending)
        XCTAssertEqual(
            try? SpeechmaticsBatchClient.decodeStatus(Data(#"{"job":{"status":"done"}}"#.utf8)),
            .finished("done"))
        for status in ["rejected", "deleted", "expired"] {
            XCTAssertThrowsError(
                try SpeechmaticsBatchClient.decodeStatus(Data(#"{"job":{"status":"\#(status)"}}"#.utf8))
            ) { error in
                XCTAssertEqual(error as? BatchTranscriptionJobError, .jobFailed("Speechmatics", status))
            }
        }
        XCTAssertThrowsError(
            try SpeechmaticsBatchClient.decodeStatus(
                Data(#"{"job":{"status":"rejected","errors":[{"message":"unsupported audio"}]}}"#.utf8))
        ) { error in
            XCTAssertEqual(
                error as? BatchTranscriptionJobError, .jobFailed("Speechmatics", "unsupported audio"))
        }
        XCTAssertThrowsError(try SpeechmaticsBatchClient.decodeStatus(Data(#"{}"#.utf8)))
    }

    /// Authentication (401, 403) and quota (402, 429) rejections keep the
    /// provider's status and body, on job creation and on the transcript fetch.
    func testAuthenticationAndQuotaFailuresKeepTheProviderStatusAndBody() async throws {
        for status in [401, 403, 402, 429] {
            let audio = try Self.fixture(extension: "wav")
            defer { try? FileManager.default.removeItem(at: audio) }
            var client = SpeechmaticsBatchClient(baseURL: baseURL)
            client.upload = { request, _ in (Data("denied".utf8), Self.response(request, status: status)) }
            await assertThrowsAsync(
                try await client.transcribeFile(
                    at: audio, apiKey: "key",
                    model: SpeechmaticsBatchClient.enhancedCatalogID, language: nil)
            ) { XCTAssertEqual($0 as? TranscriptionProviderError, .httpError(status, "denied")) }
        }

        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        var client = SpeechmaticsBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, _ in (Data(#"{"id":"job-7"}"#.utf8), Self.ok(request)) }
        client.send = { request in
            request.url?.path.hasSuffix("/transcript") == true
                ? (Data("gone".utf8), Self.response(request, status: 403))
                : (Data(#"{"job":{"status":"done"}}"#.utf8), Self.ok(request))
        }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: SpeechmaticsBatchClient.standardCatalogID, language: nil)
        ) { XCTAssertEqual($0 as? TranscriptionProviderError, .httpError(403, "gone")) }
    }

    func testCancellationDuringPollingDeletesTheJobAndSurfacesACancellationError() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let recorder = BatchRequestRecorder()
        var client = SpeechmaticsBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, _ in (Data(#"{"id":"job-7"}"#.utf8), Self.ok(request)) }
        client.send = { request in
            await recorder.record(request)
            if request.httpMethod == "DELETE" { return (Data(), Self.ok(request)) }
            throw CancellationError()
        }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: SpeechmaticsBatchClient.standardCatalogID, language: nil)
        ) { XCTAssertTrue($0 is CancellationError) }
        let deletes = await recorder.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.map(\.url?.path), ["/v2/jobs/job-7"])
        XCTAssertEqual(deletes.first?.url?.query, "force=true")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testACancelledUploadIsReportedAsCancellation() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        var client = SpeechmaticsBatchClient(baseURL: baseURL)
        client.upload = { _, _ in throw URLError(.cancelled) }
        await assertThrowsAsync(
            try await client.transcribeFile(
                at: audio, apiKey: "key", model: SpeechmaticsBatchClient.enhancedCatalogID, language: nil)
        ) { XCTAssertTrue($0 is CancellationError) }
    }

    // MARK: - Responses

    func testASilentRecordingFinalisesAsAnEmptyTranscriptRatherThanAFailure() throws {
        let silent = try SpeechmaticsBatchClient.decodeTranscript(
            Data(#"{"job":{"duration":1.0},"results":[]}"#.utf8),
            model: SpeechmaticsBatchClient.enhancedCatalogID)
        XCTAssertEqual(silent.text, "")
        XCTAssertEqual(silent.segments, [])
        XCTAssertEqual(silent.duration, 1)
        XCTAssertNil(silent.confidence)
        XCTAssertThrowsError(
            try SpeechmaticsBatchClient.decodeTranscript(
                Data(#"{"job":{}}"#.utf8), model: SpeechmaticsBatchClient.enhancedCatalogID))
        XCTAssertThrowsError(try SpeechmaticsBatchClient.decodeJobID(Data(#"{"id":""}"#.utf8)))
    }

    /// json-v2 punctuation carries a direction. `previous` follows its word
    /// with no space; `next` -- an opening bracket or quote -- takes the space
    /// before it and suppresses the one that would otherwise follow it, so the
    /// transcript reads `Hello (world)` rather than `Hello ( world)`.
    func testPunctuationAttachesInBothDirectionsWithoutStrandingASpace() throws {
        let json = """
        {"job":{"duration":2.0},"results":[
          {"type":"word","start_time":0.0,"end_time":0.4,
           "alternatives":[{"content":"Hello","confidence":0.9}]},
          {"type":"punctuation","attaches_to":"next",
           "alternatives":[{"content":"("}]},
          {"type":"word","start_time":0.5,"end_time":0.9,
           "alternatives":[{"content":"world","confidence":0.9}]},
          {"type":"punctuation","attaches_to":"previous",
           "alternatives":[{"content":")"}]},
          {"type":"punctuation","attaches_to":"previous",
           "alternatives":[{"content":"."}]}]}
        """
        let result = try SpeechmaticsBatchClient.decodeTranscript(
            Data(json.utf8), model: SpeechmaticsBatchClient.enhancedCatalogID)
        XCTAssertEqual(result.text, "Hello (world).")
        // Punctuation stays out of the timed word segments.
        XCTAssertEqual(result.segments.map(\.text), ["Hello", "world"])
    }

    /// Leading punctuation at the very start of a transcript must not open with
    /// a stray space either.
    func testLeadingPunctuationAtTheStartOfATranscriptAddsNoLeadingSpace() throws {
        let json = """
        {"job":{"duration":1.0},"results":[
          {"type":"punctuation","attaches_to":"next","alternatives":[{"content":"\\u201c"}]},
          {"type":"word","start_time":0.0,"end_time":0.4,
           "alternatives":[{"content":"Hello","confidence":0.9}]},
          {"type":"punctuation","attaches_to":"previous","alternatives":[{"content":"\\u201d"}]}]}
        """
        let result = try SpeechmaticsBatchClient.decodeTranscript(
            Data(json.utf8), model: SpeechmaticsBatchClient.enhancedCatalogID)
        XCTAssertEqual(result.text, "\u{201C}Hello\u{201D}")
    }

    func testPunctuationAttachesToTheWordItBelongsToAndNeverBecomesASegment() throws {
        let result = try SpeechmaticsBatchClient.decodeTranscript(
            Data(Self.transcript.utf8), model: SpeechmaticsBatchClient.standardCatalogID)
        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.segments.count, 2)
    }

    func testBothTiersAreInTheBatchPickerAndReuseTheLiveSpeechmaticsKey() {
        let batchIDs = Set(ModelCatalog.batchTranscription.map(\.id))
        XCTAssertTrue(batchIDs.isSuperset(of: SpeechmaticsBatchClient.catalogIDs))
        XCTAssertFalse(ModelCatalog.liveTranscription.contains {
            SpeechmaticsBatchClient.catalogIDs.contains($0.id)
        })
        for id in SpeechmaticsBatchClient.catalogIDs {
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: id, purpose: .batchTranscription),
                .apiKey(identifier: "speechmatics.apiKey", providerName: "Speechmatics"))
        }
        // The realtime entry keeps its own identifier, so an existing live
        // selection is never rewritten by the new batch entries.
        XCTAssertTrue(ModelCatalog.liveTranscription.contains { $0.id == "speechmatics/enhanced-streaming" })
    }

    // MARK: - Fixtures

    private static let transcript = """
    {"job":{"id":"job-7","duration":4.5},"results":[
      {"type":"word","start_time":0.1,"end_time":0.6,
       "alternatives":[{"content":"Hello","confidence":0.95}]},
      {"type":"word","start_time":0.7,"end_time":1.2,
       "alternatives":[{"content":"there","confidence":0.85}]},
      {"type":"punctuation","start_time":1.2,"end_time":1.2,"attaches_to":"previous",
       "alternatives":[{"content":".","confidence":1.0}]}]}
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
