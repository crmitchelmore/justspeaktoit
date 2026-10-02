import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class DesktopSonioxTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSharedRouteUploadsWAVCreatesCanonicalJobAndDeletesBothResources() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let source = try Data(contentsOf: audio)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.soniox.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            if request.httpMethod == "POST", request.url?.path == "/v1/files" {
                XCTAssertNil(request.httpBody, "Large recordings must be uploaded from a file")
                let files = try FileManager.default.contentsOfDirectory(
                    at: multipart.directory, includingPropertiesForKeys: nil
                )
                let body = try Data(contentsOf: XCTUnwrap(files.first))
                XCTAssertNotNil(body.range(of: Data("Content-Type: audio/wav\r\n".utf8)))
                XCTAssertNotNil(body.range(of: source))
            }
            if request.httpMethod == "POST", request.url?.path == "/v1/transcriptions" {
                let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                XCTAssertEqual(body?["model"] as? String, "stt-async-v5")
                XCTAssertEqual(body?["file_id"] as? String, "file-1")
                XCTAssertEqual(body?["language_hints"] as? [String], ["en"])
                XCTAssertEqual(body?["enable_speaker_diarization"] as? Bool, true)
                XCTAssertEqual(body?["enable_language_identification"] as? Bool, true)
            }
            return Self.success(request)
        }
        let result = try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "  fixture-key  ", duration: 10, language: "en_GB",
            staging: multipart.staging, session: StubURLProtocol.makeSession()
        )
        XCTAssertEqual(result.text, "Speaker 1: Hello \nSpeaker 2: there")
        XCTAssertEqual(result.duration, 1)
        XCTAssertEqual(result.segments.map(\.text), ["Speaker 1: Hello ", "Speaker 2: there"])
        XCTAssertEqual(result.segments.map(\.startTime), [0, 0.5])
        XCTAssertEqual(result.segments.map(\.endTime), [0.5, 1])
        XCTAssertEqual(result.modelIdentifier, model)
        assertDeleted(["/v1/transcriptions/job-1", "/v1/files/file-1"])
        try assertClean(multipart, audio: audio)
    }

    func testFailedJobCreationStillDeletesItsAcceptedFile() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        for failure in [StubURLProtocol.Outcome.status(500), .ok(Data("invalid JSON".utf8))] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.httpMethod == "POST", request.url?.path == "/v1/transcriptions" { return failure }
                return Self.success(request)
            }
            do {
                _ = try await transcribe(audio, multipart: multipart)
                XCTFail("Expected create failure")
            } catch { XCTAssertFalse(error is CancellationError) }
            assertDeleted(["/v1/files/file-1"])
            try assertClean(multipart, audio: audio)
        }
    }

    func testPollingAndTranscriptFailuresDeleteEveryKnownRemoteResource() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let failures: [(String, StubURLProtocol.Outcome)] = [
            ("/v1/transcriptions/job-1", .status(429)),
            ("/v1/transcriptions/job-1", .ok(Data("invalid JSON".utf8))),
            ("/v1/transcriptions/job-1", .ok(Data(Self.jobError.utf8))),
            ("/v1/transcriptions/job-1/transcript", .status(500)),
            ("/v1/transcriptions/job-1/transcript", .ok(Data("invalid JSON".utf8)))
        ]
        for (path, failure) in failures {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.httpMethod == "GET", request.url?.path == path { return failure }
                return Self.success(request)
            }
            do {
                _ = try await transcribe(audio, multipart: multipart)
                XCTFail("Expected provider or decoding failure")
            } catch { XCTAssertFalse(error is CancellationError) }
            assertDeleted(["/v1/transcriptions/job-1", "/v1/files/file-1"])
            try assertClean(multipart, audio: audio)
        }
    }

    func testCancellationDuringCreatePollOrResultFetchCleansUpAcknowledgedIDs() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        for path in ["/v1/transcriptions", "/v1/transcriptions/job-1", "/v1/transcriptions/job-1/transcript"] {
            StubURLProtocol.reset()
            let pending = expectation(description: "Pending \(path)")
            StubURLProtocol.handler = { request in
                if request.httpMethod != "DELETE", request.url?.path == path {
                    pending.fulfill()
                    return .hang
                }
                return Self.success(request)
            }
            let client = makeClient(multipart)
            let model = model
            let task = Task {
                try await client.transcribeFile(at: audio, apiKey: "fixture-key", model: model, language: nil)
            }
            await fulfillment(of: [pending], timeout: 5)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            assertDeleted(path == "/v1/transcriptions"
                ? ["/v1/files/file-1"] : ["/v1/transcriptions/job-1", "/v1/files/file-1"])
            try assertClean(multipart, audio: audio)
        }
    }

    func testFailedOrStalledJobDeletionStillAttemptsFileDeletionAndKeepsResult() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        for failedDelete in [StubURLProtocol.Outcome.status(500), .hang] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.httpMethod == "DELETE", request.url?.path == "/v1/transcriptions/job-1" {
                    return failedDelete
                }
                return Self.success(request)
            }
            var client = makeClient(multipart)
            client.cleanupTimeout = 0.05
            let result = try await client.transcribeFile(at: audio, apiKey: "fixture-key", model: model, language: nil)
            XCTAssertEqual(result.text, "Speaker 1: Hello \nSpeaker 2: there")
            assertDeleted(["/v1/transcriptions/job-1", "/v1/files/file-1"])
            try assertClean(multipart, audio: audio)
        }
    }

    func testPollingAttemptLimitRetainsTypedTimeoutAndCleansUp() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET", request.url?.path == "/v1/transcriptions/job-1" {
                return .ok(Data(#"{"id":"job-1","status":"queued"}"#.utf8), url: request.url!)
            }
            return Self.success(request)
        }
        do {
            _ = try await transcribe(audio, multipart: multipart)
            XCTFail("Expected polling deadline")
        } catch { XCTAssertEqual(error as? SonioxBatchError, .transcriptionTimedOut) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.filter { $0.httpMethod == "GET" }.count, 2)
        assertDeleted(["/v1/transcriptions/job-1", "/v1/files/file-1"])
        try assertClean(multipart, audio: audio)
    }

    func testUploadFailureCannotDeleteUnacknowledgedResources() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        StubURLProtocol.handler = { request in .status(401, Data("rejected".utf8), url: request.url!) }
        do {
            _ = try await transcribe(audio, multipart: multipart)
            XCTFail("Expected upload rejection")
        } catch { XCTAssertEqual(error as? TranscriptionProviderError, .httpError(401, "rejected")) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        assertDeleted([])
        try assertClean(multipart, audio: audio)
    }

    func testStreamingAndUnknownModelsCannotEnterTheBatchTransport() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        for model in ["soniox/stt-rt-v5-streaming", "soniox/unknown"] {
            XCTAssertNil(DesktopTranscription.provider(for: model))
            do {
                _ = try await makeClient(multipart).transcribeFile(
                    at: audio, apiKey: "fixture-key", model: model, language: nil
                )
                XCTFail("Expected unsupported model")
            } catch { XCTAssertEqual(error as? SonioxBatchError, .unsupportedModel) }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: multipart.directory.path))
    }
}

private extension DesktopSonioxTests {
    var model: String { ModelCatalog.batchTranscriptionOptions(forProvider: "soniox")[0].id }

    static let jobError = #"{"id":"job-1","status":"error","error_message":"bad audio"}"#
    static let transcript = #"""
    {"id":"job-1","text":"Hello there","tokens":[
      {"text":"Hello ","start_ms":0,"end_ms":500,"confidence":0.9,"speaker":"1"},
      {"text":"there","start_ms":500,"end_ms":1000,"confidence":0.8,"speaker":"2"}]}
    """#

    static func success(_ request: URLRequest) -> StubURLProtocol.Outcome {
        if request.httpMethod == "DELETE" { return .status(204, url: request.url!) }
        let body: String
        switch request.url?.path {
        case "/v1/files": body = #"{"id":"file-1"}"#
        // An acknowledged ID is sufficient, even when the create response omits
        // status: losing it here would leave an accepted job impossible to clean.
        case "/v1/transcriptions": body = #"{"id":"job-1"}"#
        case "/v1/transcriptions/job-1": body = #"{"id":"job-1","status":"completed","audio_duration_ms":1000}"#
        case "/v1/transcriptions/job-1/transcript": body = transcript
        default:
            XCTFail("Unexpected Soniox request \(request)")
            return .status(404, url: request.url!)
        }
        return .ok(Data(body.utf8), url: request.url!)
    }

    func fixture() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([0, 255, 255, 127]), sampleRate: 16_000)).write(to: audio)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        return audio
    }

    func makeClient(_ multipart: DesktopMultipartFixture) -> SonioxBatchClient {
        SonioxBatchClient(
            session: StubURLProtocol.makeSession(), pollingDelay: .milliseconds(1), maximumPollingAttempts: 2,
            multipartStaging: multipart.staging
        )
    }

    func transcribe(_ audio: URL, multipart: DesktopMultipartFixture) async throws -> TranscriptionResult {
        try await makeClient(multipart).transcribeFile(at: audio, apiKey: "fixture-key", model: model, language: nil)
    }

    func assertDeleted(_ paths: [String], file: StaticString = #filePath, line: UInt = #line) {
        let actual = StubURLProtocol.recordedRequests.filter { $0.httpMethod == "DELETE" }.compactMap { $0.url?.path }
        XCTAssertEqual(actual, paths, file: file, line: line)
    }

    func assertClean(_ multipart: DesktopMultipartFixture, audio: URL) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: multipart.directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
}
