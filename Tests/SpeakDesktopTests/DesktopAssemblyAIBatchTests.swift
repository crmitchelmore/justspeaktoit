import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class DesktopAssemblyAIBatchTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testBothDesktopModelsPreserveEndpointModelLanguageAndResultContracts() async throws {
        let audio = try fixture()
        for model in AssemblyAIBatchClient().supportedModels().map(\.id) {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "api.assemblyai.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "fixture-key")
                switch request.url?.path {
                case "/v2/upload":
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                    XCTAssertNil(request.httpBody, "Encoded source uploads must stream without an audio-sized copy")
                case "/v2/transcript":
                    XCTAssertEqual(request.httpMethod, "POST")
                    let body = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                    )
                    XCTAssertEqual(body["audio_url"] as? String, "https://cdn.assemblyai.com/uploaded-audio")
                    XCTAssertEqual(body["language_code"] as? String, "en")
                    XCTAssertNil(body["language_detection"])
                    let models = model == AssemblyAIModels.universal2BatchID
                        ? [AssemblyAIModels.universal2APIName]
                        : [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
                    XCTAssertEqual(body["speech_models"] as? [String], models)
                default:
                    XCTAssertEqual(request.httpMethod, "GET")
                }
                return Self.success(request)
            }
            let result = try await DesktopTranscription.transcribe(
                audioURL: audio, model: model, apiKey: " fixture-key ", duration: 7, language: "en_GB",
                session: StubURLProtocol.makeSession()
            )
            XCTAssertEqual(StubURLProtocol.recordedRequests.map(\.url?.path), [
                "/v2/upload", "/v2/transcript", "/v2/transcript/job-1"
            ])
            XCTAssertEqual(result.text, "Hello world")
            XCTAssertEqual(result.segments.map(\.text), ["Hello", "world"])
            XCTAssertEqual(result.segments.map(\.startTime), [0.1, 1.5])
            XCTAssertEqual(result.segments.map(\.endTime), [1, 2])
            XCTAssertEqual(result.confidence, 0.95)
            XCTAssertEqual(result.duration, 7, "Native duration remains authoritative, as on Apple")
            XCTAssertEqual(result.modelIdentifier, model)
            XCTAssertNil(result.cost)
            XCTAssertEqual(DesktopTranscription.provider(for: model)?.apiKeyIdentifier, "assemblyai.apiKey")
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        }
    }

    func testLanguageDetectionAndEmptyTranscriptKeepExistingFallbackSegment() async throws {
        let audio = try fixture()
        StubURLProtocol.handler = { request in
            if request.url?.path == "/v2/transcript" {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                )
                XCTAssertEqual(body["language_detection"] as? Bool, true)
                XCTAssertNil(body["language_code"])
            }
            if request.httpMethod == "GET" {
                return .ok(Data(#"{"id":"job-1","status":"completed"}"#.utf8), url: request.url!)
            }
            return Self.success(request)
        }
        let result = try await transcribe(audio)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].text, "")
        XCTAssertEqual(result.segments[0].endTime, 7)
    }

    func testTransientHTTPAndQueuedPollingPreserveRetryBudget() async throws {
        let audio = try fixture()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                let poll = StubURLProtocol.recordedRequests.filter { $0.httpMethod == "GET" }.count
                if poll == 1 { return .status(503, Data("temporary".utf8), url: request.url!) }
                if poll == 2 {
                    return .ok(Data(#"{"id":"job-1","status":"processing"}"#.utf8), url: request.url!)
                }
            }
            return Self.success(request)
        }
        let result = try await transcribe(audio)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 5)
    }

    func testTerminalProviderErrorAndTimeoutRemainTyped() async throws {
        let audio = try fixture()
        for (status, expected) in [
            ("error", TranscriptionProviderError.httpError(500, "Provider rejected audio")),
            ("processing", .httpError(408, "Transcription timed out after 120 seconds"))
        ] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.httpMethod == "GET" {
                    let body = "{\"id\":\"job-1\",\"status\":\"\(status)\",\"error\":\"Provider rejected audio\"}"
                    return .ok(Data(body.utf8), url: request.url!)
                }
                return Self.success(request)
            }
            do {
                _ = try await transcribe(audio)
                XCTFail("Expected terminal provider failure")
            } catch { XCTAssertEqual(error as? TranscriptionProviderError, expected) }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, status == "error" ? 3 : 5)
            XCTAssertFalse(StubURLProtocol.recordedRequests.contains { $0.httpMethod == "DELETE" })
        }
    }

    func testFailedUploadOrSubmissionDoesNotStartLaterStages() async throws {
        let audio = try fixture()
        for (path, status, count) in [("/v2/upload", 403, 1), ("/v2/transcript", 429, 2)] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.url?.path == path { return .status(status, Data("denied".utf8), url: request.url!) }
                return Self.success(request)
            }
            do {
                _ = try await transcribe(audio)
                XCTFail("Expected rejected request")
            } catch { XCTAssertEqual(error as? TranscriptionProviderError, .httpError(status, "denied")) }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        }
    }

    func testMalformedResponsesFailAtTheirOriginalStage() async throws {
        let audio = try fixture()
        for (path, count) in [("/v2/upload", 1), ("/v2/transcript", 2), ("/v2/transcript/job-1", 3)] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.url?.path == path { return .ok(Data("invalid-json".utf8), url: request.url!) }
                return Self.success(request)
            }
            do {
                _ = try await transcribe(audio)
                XCTFail("Expected decoding failure")
            } catch { XCTAssertTrue(error is DecodingError, "\(error)") }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        }
    }

    func testCancellationDuringEachRequestStopsWorkAndPreservesRemoteRetentionPolicy() async throws {
        let audio = try fixture()
        for (path, count) in [("/v2/upload", 1), ("/v2/transcript", 2), ("/v2/transcript/job-1", 3)] {
            StubURLProtocol.reset()
            let active = expectation(description: "Active \(path)")
            StubURLProtocol.handler = { request in
                if request.url?.path == path { active.fulfill(); return .hang }
                return Self.success(request)
            }
            let client = makeClient()
            let task = Task {
                try await client.transcribeFile(
                    at: audio, apiKey: "fixture-key", model: AssemblyAIModels.universal35ProBatchID, language: nil
                )
            }
            await fulfillment(of: [active], timeout: 5)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
            XCTAssertFalse(StubURLProtocol.recordedRequests.contains { $0.httpMethod == "DELETE" })
        }
    }

    func testNativeDurationFailureAndMissingKeyFailClearly() async throws {
        let audio = try fixture()
        StubURLProtocol.handler = { Self.success($0) }
        let client = makeClient(duration: { _ in throw CocoaError(.fileReadCorruptFile) })
        do {
            _ = try await client.transcribeFile(
                at: audio, apiKey: "fixture-key", model: AssemblyAIModels.universal35ProBatchID, language: nil
            )
            XCTFail("Expected native duration failure")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        StubURLProtocol.resetRecordedRequests()
        do {
            _ = try await client.transcribeFile(
                at: audio, apiKey: "  ", model: AssemblyAIModels.universal35ProBatchID, language: nil
            )
            XCTFail("Expected missing key failure")
        } catch { XCTAssertEqual(error as? TranscriptionProviderError, .apiKeyMissing) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 0)
    }

    func testCredentialProbePreservesCanonicalEndpointAndRedactsKey() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.assemblyai.com/v2/transcript?limit=1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "fixture-key")
            return .ok(Data("{}".utf8), url: request.url!)
        }
        let result = await makeClient().validateAPIKey("fixture-key")
        XCTAssertEqual(result.outcome, .success(message: "AssemblyAI API key validated"))
        XCTAssertNotEqual(result.debug?.requestHeaders["Authorization"], "fixture-key")
    }
}

private extension DesktopAssemblyAIBatchTests {
    static let transcript = #"""
    {"id":"job-1","status":"completed","text":"Hello world","confidence":0.95,"audio_duration":999,
     "words":[{"text":"Hello","start":100,"end":1000},{"text":"world","start":1500,"end":2000}]}
    """#

    static func success(_ request: URLRequest) -> StubURLProtocol.Outcome {
        let body: String
        switch request.url?.path {
        case "/v2/upload": body = #"{"upload_url":"https://cdn.assemblyai.com/uploaded-audio"}"#
        case "/v2/transcript": body = #"{"id":"job-1","status":"queued"}"#
        case "/v2/transcript/job-1": body = transcript
        default:
            XCTFail("Unexpected AssemblyAI request \(request)")
            return .status(404, url: request.url!)
        }
        return .ok(Data(body.utf8), url: request.url!)
    }

    func transcribe(_ audio: URL) async throws -> TranscriptionResult {
        try await makeClient().transcribeFile(
            at: audio, apiKey: "fixture-key", model: AssemblyAIModels.universal35ProBatchID, language: nil
        )
    }

    func makeClient(
        duration: @escaping @Sendable (URL) async throws -> TimeInterval = { _ in 7 }
    ) -> AssemblyAIBatchClient {
        var client = AssemblyAIBatchClient(session: StubURLProtocol.makeSession(), durationResolver: duration)
        client.pollingDelay = .milliseconds(1)
        client.maximumPollingAttempts = 3
        return client
    }

    func fixture() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([0, 255, 255, 127]), sampleRate: 16_000)).write(to: audio)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        return audio
    }
}
