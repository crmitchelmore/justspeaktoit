import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop
import SpeakTestSupport

final class DesktopKeywordBatchDeliveryTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDesktopMultipartRoutesSendOnlyTheirOwnSupportedVocabularyFields() async throws {
        for (model, field) in [
            ("openai/gpt-4o-transcribe", "prompt"),
            ("openai/whisper-1", "prompt"),
            ("groq/whisper-large-v3-turbo", "prompt"),
            ("elevenlabs/scribe_v2", "keyterms"),
            ("mistral/voxtral-mini-latest", "context_bias")
        ] {
            StubURLProtocol.reset()
            let multipart = DesktopMultipartFixture()
            defer { multipart.remove() }
            StubURLProtocol.handler = { request in
                let body = try Self.body(multipart.body(for: request))
                XCTAssertTrue(body.contains(field), "\(model) omitted \(field)")
                XCTAssertTrue(body.contains("Speak"), model)
                XCTAssertFalse(body.contains("Competing edit"))
                if field != "prompt" { XCTAssertFalse(body.contains("name=\"prompt\""), model) }
                throw URLError(.cancelled)
            }
            try await assertCancelledRoute(model: model, words: ["Speak", "Grace"], staging: multipart.staging)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1, model)
        }
    }

    func testUnsupportedOpenAIModelAndExplicitEmptyDoNotReceivePrompt() async throws {
        for (model, words) in [
            ("openai/gpt-4o-transcribe-diarize", ["Speak"]),
            ("openai/gpt-4o-transcribe", [])
        ] {
            StubURLProtocol.reset()
            let multipart = DesktopMultipartFixture()
            defer { multipart.remove() }
            StubURLProtocol.handler = { request in
                let body = try Self.body(multipart.body(for: request))
                XCTAssertFalse(body.contains("name=\"prompt\""))
                if model.contains("diarize") { XCTAssertTrue(body.contains("chunking_strategy")) }
                throw URLError(.cancelled)
            }
            try await assertCancelledRoute(model: model, words: words, staging: multipart.staging)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        }
    }

    func testDeepgramUsesModelSpecificQueryNamesAndPreservesLanguage() async throws {
        for (model, name) in [("deepgram/nova-3", "keyterm"), ("deepgram/base", "keywords")] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(query.filter { $0.name == name }.compactMap(\.value), ["Speak", "Grace"])
                XCTAssertEqual(query.first { $0.name == "language" }?.value, "fr")
                throw URLError(.cancelled)
            }
            try await assertCancelledRoute(model: model, words: ["Speak", "Grace"])
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        }
    }

    func testAssemblyBatchUsesKeytermsForProAndWordBoostForUniversal2() async throws {
        let client = AssemblyAIBatchClient()
        let models = DesktopTranscription.batchModels.filter { $0.id.hasPrefix("assemblyai/") }
        XCTAssertFalse(models.isEmpty)
        for model in models {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                if request.url?.lastPathComponent == "upload" {
                    return .ok(Data(#"{"upload_url":"https://synthetic.invalid/audio"}"#.utf8), url: request.url!)
                }
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                )
                let pro = client.mapSpeechModels(from: model.id).contains(AssemblyAIModels.universal35ProAPIName)
                XCTAssertEqual(payload[pro ? "keyterms_prompt" : "word_boost"] as? [String], ["Speak", "Grace"])
                XCTAssertNil(payload[pro ? "word_boost" : "keyterms_prompt"])
                throw URLError(.cancelled)
            }
            try await assertCancelledRoute(model: model.id, words: ["Speak", "Grace"])
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        }
    }

    func testSonioxBatchUsesTermsContextWithoutChangingDiarization() async throws {
        let model = try XCTUnwrap(DesktopTranscription.batchModels.first { $0.id.hasPrefix("soniox/") }).id
        StubURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { return .ok(Data(), url: request.url!) }
            if request.url?.lastPathComponent == "files" {
                return .ok(Data(#"{"id":"synthetic-file"}"#.utf8), url: request.url!)
            }
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertEqual((payload["context"] as? [String: [String]])?["terms"], ["Speak", "Grace"])
            XCTAssertEqual(payload["enable_speaker_diarization"] as? Bool, true)
            XCTAssertEqual(payload["language_hints"] as? [String], ["fr"])
            throw URLError(.cancelled)
        }
        try await assertCancelledRoute(model: model, words: ["Speak", "Grace"])
        XCTAssertTrue(StubURLProtocol.recordedRequests.contains { $0.url?.lastPathComponent == "transcriptions" })
    }

    func testMetaAndExistingXAIBatchMappingsAreReachedByDesktopDispatch() async throws {
        let meta = try XCTUnwrap(DesktopTranscription.batchModels.first { $0.id.hasPrefix("meta/") }).id
        StubURLProtocol.handler = { request in
            let body = try Self.body(StubURLProtocol.body(of: request))
            XCTAssertTrue(body.contains("keywords"))
            XCTAssertTrue(body.contains("Speak"))
            throw URLError(.cancelled)
        }
        try await assertCancelledRoute(model: meta, words: ["Speak", "Grace"])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        var xai = XAIBatchTranscriptionClient()
        xai.uploadRecording = { _, file in
            let body = try Self.body(Data(contentsOf: file))
            XCTAssertTrue(body.contains("name=\"keyterm\""))
            XCTAssertTrue(body.contains("Speak"))
            throw URLError(.cancelled)
        }
        try await assertCancelledRoute(model: XAISpeechToText.batchCatalogID, words: ["Speak", "Grace"], xai: xai)
    }

    func testSpeechmaticsDispatchSerializesWordsInTheActualOwnedUploadFile() async throws {
        try await assertCancelledRoute(model: "speechmatics/enhanced", words: ["Speak", "Grace"])
    }

    func testGeminiKeepsAnnotationsWithoutVocabularyAndReportsTheLimitation() async throws {
        let model = try XCTUnwrap(GeminiTranscribeModels.directBatchModelIDs.sorted().first)
        StubURLProtocol.handler = { request in
            let body = try Self.body(StubURLProtocol.body(of: request))
            XCTAssertTrue(body.contains("timestamp_granularities"))
            XCTAssertTrue(body.contains("diarization_mode"))
            XCTAssertFalse(body.contains("custom_vocabulary"))
            XCTAssertFalse(body.contains("Speak"))
            throw URLError(.cancelled)
        }
        try await assertCancelledRoute(model: model, words: ["Speak"])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertNotNil(DesktopTranscription.keywordLimitation(model: model))
    }

    func testExistingAzurePhraseListMappingReceivesTheDesktopWords() async throws {
        let model = try XCTUnwrap(DesktopTranscription.batchModels.first {
            DesktopTranscription.provider(for: $0.id)?.id == "azure"
        }).id
        StubURLProtocol.handler = { request in
            let body = try Self.body(StubURLProtocol.body(of: request))
            XCTAssertTrue(body.contains("phraseList"))
            XCTAssertTrue(body.contains("Speak"))
            throw URLError(.cancelled)
        }
        try await assertCancelledRoute(model: model, words: ["Speak"])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    private static func body(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    private func assertCancelledRoute(
        model: String, words: [String], staging: SharedMultipartUploadStaging? = nil,
        xai: XAIBatchTranscriptionClient? = nil
    ) async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        do {
            _ = try await DesktopTranscription.transcribe(
                audioURL: audio, model: model, apiKey: "synthetic", duration: 1,
                language: "fr_FR", azureEndpoint: "https://synthetic.cognitiveservices.azure.com",
                staging: staging ?? multipart.staging, keywords: words, session: StubURLProtocol.makeSession(),
                xaiClient: xai, makeSpeechmaticsClient: { session, keywords in
                    XCTAssertEqual(keywords, words)
                    var client = SpeechmaticsBatchClient(session: session, keywords: keywords)
                    client.upload = { _, file in
                        let body = try Self.body(Data(contentsOf: file))
                        XCTAssertTrue(body.contains("additional_vocab"))
                        XCTAssertTrue(body.contains("Speak"))
                        throw URLError(.cancelled)
                    }
                    return client
                }
            )
            XCTFail("Synthetic transport must cancel after inspecting the real serialized request")
        } catch is CancellationError {
            // The test transport never performs an actual HTTP request.
        }
    }
}
