import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopAdditionalProvidersTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testGroqModelsUseSharedCompatibleTransportAndKeepProviderCredentials() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in GroqBatchClient().supportedModels() {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
                let body = StubURLProtocol.body(of: request)
                let apiModel = model.id.split(separator: "/").last!
                XCTAssertNotNil(body.range(of: Data("name=\"model\"\r\n\r\n\(apiModel)\r\n".utf8)))
                XCTAssertNotNil(body.range(of: Data("name=\"response_format\"\r\n\r\nverbose_json\r\n".utf8)))
                XCTAssertNotNil(body.range(of: Data("name=\"language\"\r\n\r\nen\r\n".utf8)))
                XCTAssertNotNil(body.range(of: Data("Content-Type: audio/wav".utf8)))
                return .ok(Data(#"{"text":"Groq result","duration":2.5}"#.utf8), url: request.url!)
            }
            let result = try await transcribe(audio, model: model.id)
            XCTAssertEqual(result.text, "Groq result")
            XCTAssertEqual(result.duration, 2.5)
            XCTAssertEqual(result.modelIdentifier, model.id)
            XCTAssertEqual(DesktopTranscription.provider(for: model.id)?.apiKeyIdentifier, "groq.apiKey")
        }
    }

    func testEveryDeepgramModelPreservesNativeRequestContractAndWordTimings() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)
        for model in DeepgramBatchClient().supportedModels() {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "api.deepgram.com")
                XCTAssertEqual(request.url?.path, "/v1/listen")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token desktop-test")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
                XCTAssertEqual(StubURLProtocol.body(of: request), bytes)
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let parameters = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(parameters["model"], model.id.split(separator: "/").last.map(String.init))
                XCTAssertEqual(parameters["language"], "en")
                for key in ["punctuate", "numerals", "utterances"] { XCTAssertEqual(parameters[key], "true") }
                return .ok(Data(Self.deepgramResult.utf8), url: request.url!)
            }
            let result = try await transcribe(audio, model: model.id)
            XCTAssertEqual(result.text, "Hello Deepgram")
            XCTAssertEqual(result.duration, 7)
            XCTAssertEqual(result.modelIdentifier, model.id)
            XCTAssertEqual(result.confidence, 0.95)
            XCTAssertEqual(result.segments.map(\.text), ["Hello", "Deepgram"])
            XCTAssertEqual(result.segments.last?.endTime, 1.4)
            XCTAssertEqual(DesktopTranscription.provider(for: model.id)?.apiKeyIdentifier, "deepgram.apiKey")
        }
    }

    func testXAIRouteUsesDedicatedEndpointAndPreservesTypedWordResponse() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, XAISpeechToText.restEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
            return .ok(Data(Self.xaiResult.utf8), url: request.url!)
        }
        let result = try await transcribe(audio, model: XAISpeechToText.batchCatalogID)
        XCTAssertEqual(result.text, "Hello xAI")
        XCTAssertEqual(result.modelIdentifier, XAISpeechToText.batchCatalogID)
        XCTAssertEqual(result.duration, 3)
        XCTAssertEqual(result.segments.last?.endTime, 1.2)
        XCTAssertNotNil(result.cost)
        XCTAssertEqual(
            DesktopTranscription.provider(for: XAISpeechToText.batchCatalogID)?.apiKeyIdentifier, "xai.apiKey"
        )
        XCTAssertNil(DesktopTranscription.provider(for: XAISpeechToText.liveCatalogID))
    }

    func testNewRoutesCancelAnActiveRequestWithoutDeletingSourceAudio() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let models = GroqBatchClient().supportedModels() + DeepgramBatchClient().supportedModels()
            + ElevenLabsBatchClient().supportedModels()
        let identifiers = models.map(\.id) + [XAISpeechToText.batchCatalogID, GeminiTranscribeModels.batchCatalogID]
        for model in identifiers {
            StubURLProtocol.reset()
            let uploading = expectation(description: "Uploading to \(model)")
            StubURLProtocol.handler = { _ in uploading.fulfill(); return .hang }
            let task = Task { try await self.transcribe(audio, model: model) }
            await fulfillment(of: [uploading], timeout: 5)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        }
    }

    func testDeepgramEmptySpeechStaysEmptyAndRejectsMalformedPayload() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = try XCTUnwrap(DeepgramBatchClient().supportedModels().first?.id)
        StubURLProtocol.handler = { request in .ok(Data(#"{"results":{"channels":[]}}"#.utf8), url: request.url!) }
        let result = try await transcribe(audio, model: model)
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.duration, 7)
        StubURLProtocol.handler = { request in .ok(Data("malformed".utf8), url: request.url!) }
        do {
            _ = try await transcribe(audio, model: model)
            XCTFail("Expected response decoding failure")
        } catch { XCTAssertTrue(error is DecodingError) }
    }

    func testGroqAndDeepgramNeverExposeUnknownOrStreamingModels() {
        for model in ["groq/unknown", "deepgram/unknown", "deepgram/nova-3-streaming"] {
            XCTAssertNil(DesktopTranscription.provider(for: model))
            XCTAssertFalse(DesktopTranscription.batchModels.contains { $0.id == model })
        }
    }
}

private extension DesktopAdditionalProvidersTests {
    static let xaiResult = #"""
    {"text":"Hello xAI","duration":3,"words":[{"text":"Hello","start":0.1,"end":0.5},
        {"text":"xAI","start":0.6,"end":1.2}]}
    """#
}

private extension DesktopAdditionalProvidersTests {
    static let deepgramResult = #"""
    {"results":{"channels":[{"alternatives":[{"transcript":"Hello Deepgram","confidence":0.95,
        "words":[{"word":"Hello","start":0.1,"end":0.6},{"word":"Deepgram","start":0.7,"end":1.4}]}]}]}}
    """#
}

private extension DesktopAdditionalProvidersTests {
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
}
