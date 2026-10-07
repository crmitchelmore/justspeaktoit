import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class DesktopRevAITests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDesktopRouteStreamsMediaWithCanonicalLanguageAndDiarizationFields() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let source = try Data(contentsOf: audio)
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertNil(request.httpBody, "Rev.ai must use the shared streamed upload")
                let files = try FileManager.default.contentsOfDirectory(
                    at: multipart.directory, includingPropertiesForKeys: nil
                )
                let body = try Data(contentsOf: XCTUnwrap(files.first))
                for field in ["name=\"media\"", "name=\"metadata\"", "Content-Type: audio/wav",
                              #""language":"en""#, #""skip_diarization":false"#, #""skip_punctuation":false"#] {
                    XCTAssertNotNil(body.range(of: Data(field.utf8)), field)
                }
                XCTAssertNotNil(body.range(of: source))
            }
            return Self.success(request)
        }
        let result = try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "fixture-key", duration: 7, language: "en_GB",
            staging: multipart.staging, session: StubURLProtocol.makeSession()
        )
        XCTAssertEqual(result.duration, 7)
        XCTAssertEqual(DesktopTranscription.provider(for: model)?.apiKeyIdentifier, "revai.apiKey")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: multipart.directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testSharedClientPreservesRevAIJobProtocolAndTranscriptMapping() async throws {
        let audio = try fixture()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.rev.ai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            if request.url?.path.hasSuffix("/transcript") == true {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.rev.transcript.v1.0+json")
            }
            return Self.success(request)
        }
        let result = try await makeClient().transcribeFile(
            at: audio, apiKey: "fixture-key", model: model, language: "en_GB"
        )
        XCTAssertEqual(StubURLProtocol.recordedRequests.map(\.url?.path), [
            "/speechtotext/v1/jobs", "/speechtotext/v1/jobs/job-1", "/speechtotext/v1/jobs/job-1/transcript"
        ])
        XCTAssertEqual(result.text, "Hello . More words")
        XCTAssertEqual(result.segments.map(\.text), ["Hello", "More words"])
        XCTAssertEqual(result.segments.map(\.startTime), [0.1, 1.5])
        XCTAssertEqual(result.segments.map(\.endTime), [1, 2])
        XCTAssertEqual(result.modelIdentifier, model)
        XCTAssertEqual(result.duration, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testFailedJobAndExhaustedPollingKeepExistingTypedErrors() async throws {
        let audio = try fixture()
        for (status, expected) in [
            ("failed", TranscriptionProviderError.httpError(500, "Rev.ai transcription failed")),
            ("in_progress", TranscriptionProviderError.httpError(408, "Rev.ai transcription timed out"))
        ] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.httpMethod == "GET" {
                    return .ok(Data("{\"id\":\"job-1\",\"status\":\"\(status)\"}".utf8), url: request.url!)
                }
                return Self.success(request)
            }
            do {
                _ = try await makeClient().transcribeFile(at: audio, apiKey: "fixture-key", model: model, language: nil)
                XCTFail("Expected terminal job failure")
            } catch { XCTAssertEqual(error as? TranscriptionProviderError, expected) }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, status == "failed" ? 2 : 3)
        }
    }

    func testNativeDurationFailureIsPreservedByTheThrowingAdapterSeam() async throws {
        let audio = try fixture()
        StubURLProtocol.handler = { Self.success($0) }
        let client = makeClient(duration: { _ in throw CocoaError(.fileReadCorruptFile) })
        do {
            _ = try await client.transcribeFile(at: audio, apiKey: "fixture-key", model: model, language: nil)
            XCTFail("Expected native duration failure")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 3)
    }

    func testCancellationStopsPollingAndRetainsSourceAudio() async throws {
        let audio = try fixture()
        let polling = expectation(description: "Accepted Rev.ai job")
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { polling.fulfill(); return .hang }
            return Self.success(request)
        }
        let client = makeClient()
        let model = model
        let task = Task {
            try await client.transcribeFile(at: audio, apiKey: "fixture-key", model: model, language: nil)
        }
        await fulfillment(of: [polling], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testCredentialProbeRetainsCanonicalEndpointAndRedactsKey() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.rev.ai/speechtotext/v1/jobs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            return .ok(Data("[]".utf8), url: request.url!)
        }
        let result = await makeClient().validateAPIKey("fixture-key")
        XCTAssertEqual(result.outcome, .success(message: "Rev.ai API key validated"))
        XCTAssertNotEqual(result.debug?.requestHeaders["Authorization"], "Bearer fixture-key")
    }
}

private extension DesktopRevAITests {
    var model: String { ModelCatalog.batchTranscriptionOptions(forProvider: "revai")[0].id }

    static func success(_ request: URLRequest) -> StubURLProtocol.Outcome {
        let body: String
        switch request.url?.path {
        case "/speechtotext/v1/jobs": body = #"{"id":"job-1","status":"in_progress"}"#
        case "/speechtotext/v1/jobs/job-1": body = #"{"id":"job-1","status":"transcribed"}"#
        case "/speechtotext/v1/jobs/job-1/transcript": body = transcript
        default:
            XCTFail("Unexpected Rev.ai request \(request)")
            return .status(404, url: request.url!)
        }
        return .ok(Data(body.utf8), url: request.url!)
    }

    static let transcript = #"""
    {"monologues":[{"speaker":0,"elements":[
      {"type":"text","value":"Hello","ts":0.1,"end_ts":1},{"type":"punct","value":"."}]},
      {"speaker":1,"elements":[{"type":"text","value":"More words","ts":1.5,"end_ts":2}]}]}
    """#

    func makeClient(
        duration: @escaping @Sendable (URL) async throws -> TimeInterval = { _ in 7 }
    ) -> RevAIBatchClient {
        let multipart = DesktopMultipartFixture()
        addTeardownBlock { multipart.remove() }
        var client = RevAIBatchClient(
            session: StubURLProtocol.makeSession(), multipartStaging: multipart.staging, durationResolver: duration
        )
        client.pollingDelay = .milliseconds(1)
        client.maximumPollingAttempts = 2
        return client
    }

    func fixture() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([0, 255, 255, 127]), sampleRate: 16_000)).write(to: audio)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        return audio
    }
}
