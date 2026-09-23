import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class DesktopScribeGeminiTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testElevenLabsReusesScribeModelKeyAndWordTimingContract() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in ElevenLabsBatchClient().supportedModels() {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
                XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "desktop-test")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = StubURLProtocol.body(of: request)
                let apiModel = model.id.split(separator: "/").last!
                for field in [
                    "name=\"model_id\"\r\n\r\n\(apiModel)\r\n",
                    "name=\"timestamps_granularity\"\r\n\r\nword\r\n",
                    "name=\"language_code\"\r\n\r\nen\r\n",
                    "Content-Type: audio/wav"
                ] { XCTAssertNotNil(body.range(of: Data(field.utf8))) }
                let response = #"""
                {"text":"Hello Scribe","language_code":"en","words":[
                    {"type":"word","text":"Hello","start":0.1,"end":0.4},
                    {"type":"spacing","text":" ","start":0.4,"end":0.4},
                    {"type":"word","text":"Scribe","start":0.5,"end":0.9}]}
                """#
                return .ok(Data(response.utf8), url: request.url!)
            }
            let result = try await transcribe(audio, model: model.id)
            XCTAssertEqual(result.text, "Hello Scribe")
            XCTAssertEqual(result.duration, 7)
            XCTAssertEqual(result.modelIdentifier, model.id)
            XCTAssertEqual(result.segments.map(\.text), ["Hello", "Scribe"])
            XCTAssertEqual(result.segments.last?.endTime, 0.9)
            XCTAssertEqual(DesktopTranscription.provider(for: model.id)?.apiKeyIdentifier, "elevenlabs.apiKey")
        }
    }

    func testGeminiUsesDirectInteractionsContractAndInjectedDuration() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, GeminiTranscribeModels.interactionsURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader), "desktop-test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, GeminiTranscribeModels.batchAPIName)
            let input = (body?["input"] as? [[String: Any]])?.first
            XCTAssertEqual(input?["mime_type"] as? String, "audio/wav")
            XCTAssertEqual(input?["data"] as? String, bytes.base64EncodedString())
            let generation = body?["generation_config"] as? [String: Any]
            let transcription = generation?["transcription_config"] as? [String: Any]
            XCTAssertEqual(transcription?["language_codes"] as? [String], ["en-GB"])
            let mode = transcription?["mode"] as? [String: Any]
            XCTAssertEqual(mode?["type"] as? String, "verbatim")
            XCTAssertEqual(mode?["timestamp_granularities"] as? [String], ["word"])
            XCTAssertEqual(mode?["diarization_mode"] as? String, "speaker")
            return .ok(Data(Self.geminiResult.utf8), url: request.url!)
        }
        let result = try await transcribe(audio, model: GeminiTranscribeModels.batchCatalogID)
        XCTAssertEqual(result.text, "Hello Gemini")
        XCTAssertEqual(result.duration, 7)
        XCTAssertEqual(result.modelIdentifier, GeminiTranscribeModels.batchCatalogID)
        XCTAssertEqual(result.segments.map(\.text), ["Hello", "Gemini"])
        XCTAssertEqual(result.segments.last?.endTime, 0.9)
        XCTAssertTrue(result.rawPayload?.contains("spk_2") == true)
        // The OpenRouter-routed Gemini 2.0 entry shares the google/ prefix but never the Google credential.
        let routedThroughOpenRouter = DesktopTranscription.provider(for: "google/gemini-2.0-flash-001")
        XCTAssertEqual(routedThroughOpenRouter?.id, OpenRouterService.providerID)
    }

    func testGeminiStagedUploadKeepsSnapshotAndPollsBeforeTranscription() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)
        let snapshot = GeminiUploadSnapshot()
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/upload/v1beta/files":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "start")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length"), "\(bytes.count)"
                )
                return .respond(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
                    "X-Goog-Upload-URL": Self.uploadURL.absoluteString
                ])!, Data())
            case "/v1beta/files/desktop":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader), "desktop-test")
                return .ok(Data(#"{"state":"ACTIVE"}"#.utf8), url: request.url!)
            default:
                XCTAssertEqual(request.url, GeminiTranscribeModels.interactionsURL)
                let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                let input = (body?["input"] as? [[String: Any]])?.first
                XCTAssertEqual(input?["uri"] as? String, Self.fileURI)
                XCTAssertNil(input?["data"])
                return .ok(Data(Self.geminiResult.utf8), url: request.url!)
            }
        }
        var client = GeminiInteractionsClient(
            session: StubURLProtocol.makeSession(), inlineAudioByteLimit: 0, filePollInterval: 0,
            durationResolver: { _ in 7 })
        client.uploadRecording = { request, file in
            await snapshot.record(file)
            XCTAssertEqual(request.url, Self.uploadURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "upload, finalize")
            XCTAssertNil(request.httpBody)
            XCTAssertNotEqual(file, audio)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            let response = #"{"file":{"name":"files/desktop","uri":"\#(Self.fileURI)","state":"PROCESSING"}}"#
            return (Data(response.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        let result = try await client.transcribeFile(at: audio, apiKey: "desktop-test", language: nil)
        XCTAssertEqual(result.duration, 7)
        XCTAssertEqual(StubURLProtocol.recordedRequests.map(\.url?.path), [
            "/upload/v1beta/files", "/v1beta/files/desktop", "/v1beta/interactions"
        ])
        let staged = await snapshot.file
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staged).path))
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }

    func testGeminiCancelledUploadDeletesOnlyItsPrivateSnapshot() async throws {
        let audio = try fixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let snapshot = GeminiUploadSnapshot()
        StubURLProtocol.handler = { request in
            .respond(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
                "X-Goog-Upload-URL": Self.uploadURL.absoluteString
            ])!, Data())
        }
        var client = GeminiInteractionsClient(
            session: StubURLProtocol.makeSession(), inlineAudioByteLimit: 0, durationResolver: { _ in 7 }
        )
        client.uploadRecording = { _, file in
            await snapshot.record(file)
            throw URLError(.cancelled)
        }
        do {
            _ = try await client.transcribeFile(at: audio, apiKey: "desktop-test", language: nil)
            XCTFail("Expected upload cancellation")
        } catch {
            XCTAssertTrue(BatchTranscriptionJob.mapCancellation(error) is CancellationError)
        }
        let staged = await snapshot.file
        let directory = try XCTUnwrap(staged).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }
}

private extension DesktopScribeGeminiTests {
    static let uploadURL = URL(string: "https://generativelanguage.googleapis.com/upload/session/desktop")!
    static let fileURI = "https://generativelanguage.googleapis.com/v1beta/files/desktop"
    static let geminiResult = #"""
    {"status":"completed","output_text":"Hello Gemini","steps":[{"type":"model_output","content":[
      {"type":"text","text":"Hello Gemini","annotations":[
        {"type":"word_info","text":"Hello","speaker":"spk_1","start_offset":"0.1s","end_offset":"0.4s"},
        {"type":"word_info","text":"Gemini","speaker":"spk_2","start_offset":"0.5s","end_offset":"0.9s"}
      ]}]}]}
    """#

    func transcribe(_ audio: URL, model: String) async throws -> TranscriptionResult {
        try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "desktop-test", duration: 7,
            language: "en_GB", session: StubURLProtocol.makeSession()
        )
    }

    func fixture() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: audio)
        return audio
    }
}

private actor GeminiUploadSnapshot {
    var file: URL?
    func record(_ url: URL) { file = url }
}
