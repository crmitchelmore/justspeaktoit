import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopTranscriptionTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDescriptorsUseCanonicalCredentialsAndAccountURLs() throws {
        for model in DesktopTranscription.batchModels {
            let descriptor = try XCTUnwrap(DesktopTranscription.provider(for: model.id))
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: model.id, purpose: .batchTranscription),
                .apiKey(identifier: descriptor.apiKeyIdentifier, providerName: descriptor.displayName)
            )
            XCTAssertEqual(descriptor.id, ModelRouting.family(for: model.id).providerID)
            XCTAssertEqual(descriptor.apiKeyLabel, descriptor.displayName + " API Key")
            let accountURL = descriptor.id == GroqBatchClient().metadata.id
                ? GroqBatchClient().metadata.apiKeyURL : LiveTranscriptionProviderID(rawValue: descriptor.id)?.apiKeyURL
            XCTAssertEqual(descriptor.apiKeyURL, accountURL)
            XCTAssertNotNil(descriptor.apiKeyURL)
        }
        XCTAssertNil(DesktopTranscription.provider(for: "apple/local/SFSpeechRecognizer"))
        XCTAssertNil(DesktopTranscription.provider(for: "cartesia/ink-2-streaming"))
        XCTAssertNil(DesktopTranscription.provider(for: "openai/gpt-4o-audio-preview-2024-12-17"))
    }

    func testEveryOpenAIModelStillUsesTheExistingSharedClient() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in OpenAITranscriptionModels.directBatchModelIDs.sorted() {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "api.openai.com")
                XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
                return .ok(Data(#"{"text":"Shared OpenAI result"}"#.utf8), url: request.url!)
            }
            let result = try await transcribe(audio, model: model)
            XCTAssertEqual(result.text, "Shared OpenAI result")
            XCTAssertEqual(result.modelIdentifier, model)
            XCTAssertEqual(result.duration, 7)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        }
    }

    func testCartesiaRoutePreservesProviderVersionAndWordTimings() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.cartesia.ai/stt")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaBatchClient.apiVersion)
            let response = #"""
            {"type":"transcript","text":"Hello Cartesia","duration":2.5,
             "words":[{"word":"Hello","start":0.1,"end":0.5},{"word":"Cartesia","start":0.7,"end":1.2}]}
            """#
            return .ok(Data(response.utf8), url: request.url!)
        }
        let result = try await transcribe(audio, model: CartesiaBatchClient.catalogID)
        XCTAssertEqual(result.text, "Hello Cartesia")
        XCTAssertEqual(result.duration, 2.5)
        XCTAssertEqual(result.modelIdentifier, CartesiaBatchClient.catalogID)
        XCTAssertEqual(result.segments.map(\.text), ["Hello", "Cartesia"])
        XCTAssertEqual(result.segments.last?.endTime, 1.2)
    }

    func testGladiaRouteCompletesUploadCreateAndPollWithItsOwnCredential() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.gladia.io")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "desktop-test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            switch request.url?.path {
            case "/v2/upload":
                return .ok(Data(#"{"audio_url":"https://api.gladia.io/audio/fixture"}"#.utf8), url: request.url!)
            case "/v2/pre-recorded":
                let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                XCTAssertEqual(body?["model"] as? String, "solaria-1")
                let languages = body?["language_config"] as? [String: Any]
                XCTAssertEqual(languages?["languages"] as? [String], ["en"])
                return .ok(Data(#"{"id":"desktop-job"}"#.utf8), url: request.url!)
            default:
                XCTAssertEqual(request.url?.path, "/v2/pre-recorded/desktop-job")
                return .ok(Data(Self.gladiaResult.utf8), url: request.url!)
            }
        }
        let result = try await transcribe(audio, model: GladiaBatchClient.catalogID)
        XCTAssertEqual(result.text, "Hello Gladia")
        XCTAssertEqual(result.duration, 3.25)
        XCTAssertEqual(result.modelIdentifier, GladiaBatchClient.catalogID)
        XCTAssertEqual(result.segments.last?.endTime, 1.2)
        XCTAssertEqual(StubURLProtocol.recordedRequests.map(\.url?.path), [
            "/v2/upload", "/v2/pre-recorded", "/v2/pre-recorded/desktop-job"
        ])
    }

    func testBothSpeechmaticsTiersCompleteTheCanonicalJobProtocol() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in SpeechmaticsBatchClient.catalogIDs.sorted() {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "eu1.asr.api.speechmatics.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
                switch request.url?.path {
                case "/v2/jobs":
                    return .ok(Data(#"{"id":"desktop-job"}"#.utf8), url: request.url!)
                case "/v2/jobs/desktop-job":
                    return .ok(Data(#"{"job":{"status":"done"}}"#.utf8), url: request.url!)
                default:
                    XCTAssertEqual(request.url?.path, "/v2/jobs/desktop-job/transcript")
                    XCTAssertEqual(request.url?.query, "format=json-v2")
                    return .ok(Data(Self.speechmaticsResult.utf8), url: request.url!)
                }
            }
            let result = try await transcribe(audio, model: model)
            XCTAssertEqual(result.text, "Hello Speechmatics.")
            XCTAssertEqual(result.duration, 4.5)
            XCTAssertEqual(result.modelIdentifier, model)
            XCTAssertEqual(result.segments.map(\.text), ["Hello", "Speechmatics"])
            XCTAssertEqual(StubURLProtocol.recordedRequests.map(\.url?.path), [
                "/v2/jobs", "/v2/jobs/desktop-job", "/v2/jobs/desktop-job/transcript"
            ])
        }
    }

    func testEveryRoutePreservesAuthenticationAndQuotaFailures() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in DesktopTranscription.batchModels {
            for status in [401, 429] {
                StubURLProtocol.reset()
                StubURLProtocol.handler = { request in
                    .status(status, Data(Self.rejection.utf8), url: request.url!)
                }
                do {
                    _ = try await transcribe(audio, model: model.id)
                    XCTFail("Expected failure for \(model.id)")
                } catch {
                    assertProviderFailure(error, model: model.id, status: status)
                }
                XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
            }
        }
    }

    func testEveryRouteNormalisesTransportCancellationAndRetainsSourceAudio() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in DesktopTranscription.batchModels {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
            do {
                _ = try await transcribe(audio, model: model.id)
                XCTFail("Expected transport cancellation for \(model.id)")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        }
    }

    func testRejectedModelOrMissingCredentialNeverReachesTheNetwork() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            _ = try await transcribe(audio, model: "openai/not-a-real-model")
            XCTFail("Expected unsupported model")
        } catch {
            guard case DesktopTranscriptionError.unsupportedModel = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
        for model in DesktopTranscription.batchModels {
            do {
                _ = try await DesktopTranscription.transcribe(
                    audioURL: audio, model: model.id, apiKey: "  \n", duration: 0,
                    session: StubURLProtocol.makeSession()
                )
                XCTFail("Expected missing credential")
            } catch {
                XCTAssertEqual(error as? TranscriptionProviderError, .apiKeyMissing)
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testCancelledRequestNeverStartsAnyProviderUpload() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in DesktopTranscription.batchModels {
            let session = StubURLProtocol.makeSession()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await DesktopTranscription.transcribe(
                    audioURL: audio, model: model.id, apiKey: "desktop-test", duration: 0, session: session
                )
            }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testCancellingAcceptedGladiaAndSpeechmaticsJobsSendsProviderCleanup() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in [GladiaBatchClient.catalogID, SpeechmaticsBatchClient.enhancedCatalogID] {
            StubURLProtocol.reset()
            let polling = expectation(description: "Provider accepted \(model) job")
            let session = StubURLProtocol.makeSession()
            StubURLProtocol.handler = { request in
                if request.httpMethod == "DELETE" {
                    return .ok(Data("{}".utf8), url: request.url!)
                }
                if request.httpMethod == "POST" {
                    let response = request.url?.path == "/v2/upload"
                        ? #"{"audio_url":"https://api.gladia.io/audio/fixture"}"#
                        : #"{"id":"cancel-job"}"#
                    return .ok(Data(response.utf8), url: request.url!)
                }
                polling.fulfill()
                return .hang
            }
            let task = Task {
                try await DesktopTranscription.transcribe(
                    audioURL: audio, model: model, apiKey: "desktop-test", duration: 0, session: session
                )
            }
            await fulfillment(of: [polling], timeout: 5)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            let deletion = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(deletion.httpMethod, "DELETE")
            XCTAssertTrue(deletion.url?.path.hasSuffix("/cancel-job") == true)
            if model == SpeechmaticsBatchClient.enhancedCatalogID {
                XCTAssertEqual(deletion.url?.query, "force=true")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        }
    }

}

private extension DesktopTranscriptionTests {
    static let rejection = #"{"error":{"message":"provider rejection"}}"#

    func assertProviderFailure(_ error: Error, model: String, status: Int) {
        if model == XAISpeechToText.batchCatalogID {
            let expected: XAISpeechToTextError = status == 401
                ? .unauthorized(statusCode: status) : .rateLimited(message: "provider rejection")
            XCTAssertEqual(error as? XAISpeechToTextError, expected)
        } else if GeminiTranscribeModels.directBatchModelIDs.contains(model) {
            if status == 401 {
                guard case StreamingClientError.invalidAPIKey(let provider) = error else {
                    return XCTFail("Unexpected Google error: \(error)")
                }
                XCTAssertEqual(provider, GeminiTranscribeModels.providerDisplayName)
            } else {
                XCTAssertEqual(error as? GeminiBatchError, .rateLimited("provider rejection"))
            }
        } else {
            XCTAssertEqual(error as? TranscriptionProviderError, .httpError(status, Self.rejection))
        }
    }

    func transcribe(_ audio: URL, model: String) async throws -> TranscriptionResult {
        try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "  desktop-test  ", duration: 7,
            language: "en_GB", session: StubURLProtocol.makeSession()
        )
    }

    func fixture() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: audio)
        return audio
    }

    static let gladiaResult = #"""
    {"status":"done","result":{"metadata":{"audio_duration":3.25},"transcription":{
      "full_transcript":"Hello Gladia",
      "utterances":[{"start":0.1,"end":0.6,"text":"Hello","confidence":0.9},
                    {"start":0.7,"end":1.2,"text":"Gladia","confidence":0.9}]}}}
    """#

    static let speechmaticsResult = #"""
    {"job":{"duration":4.5},"results":[
      {"type":"word","start_time":0.1,"end_time":0.6,"alternatives":[{"content":"Hello","confidence":0.9}]},
      {"type":"word","start_time":0.7,"end_time":1.2,"alternatives":[{"content":"Speechmatics","confidence":0.9}]},
      {"type":"punctuation","attaches_to":"previous","alternatives":[{"content":"."}]}]}
    """#
}
