import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class Voxtral3BatchTransportTests: DeepgramSpeechStubTestCase {
    func testBothFileModels_UploadAudioWithVocabularyAndDecodeTheCompleteTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("speech.wav")
        try DeepgramSpeechFixture.canonicalWAV(pcm: pcm).write(to: audioURL)
        let stagingURL = directory.appendingPathComponent("uploads")
        let staging = SharedMultipartUploadStaging(directory: stagingURL, securityPolicy: .posix)
        let client = MistralBatchClient(
            session: session, multipartStaging: staging, keywords: ["Alder Creek Design"],
            durationResolver: { _ in 2 })
        for model in MistralVoxtral3.batchIDs {
            let apiModel = String(model.dropFirst("mistral/".count))
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                // URLSession's file upload is staged on disk; inspect the actual admitted body.
                let files = try FileManager.default.contentsOfDirectory(at: stagingURL,
                    includingPropertiesForKeys: nil)
                let upload = try XCTUnwrap(files.count == 1 ? files.first : nil)
                let body = try Data(contentsOf: upload)
                XCTAssertNotNil(body.range(of: Data(("name=\"model\"\r\n\r\n" + apiModel).utf8)))
                XCTAssertNotNil(body.range(of: Data("name=\"context_bias\"\r\n\r\nAlder Creek Design".utf8)))
                XCTAssertNotNil(body.range(of: Data("name=\"language\"\r\n\r\nen".utf8)))
                XCTAssertNil(body.range(of: Data("timestamp_granularities".utf8)))
                let payload = try JSONSerialization.data(withJSONObject: [
                    "text": "Alder Creek Design.", "language": "en",
                    "segments": [["start": 0, "end": 2, "text": "Alder Creek Design."]]
                ])
                return .respond(DeepgramSpeechFixture.response(request), payload)
            }
            let result = try await client.transcribeFile(
                at: audioURL, apiKey: "fixture-key", model: model, language: "en_GB")
            XCTAssertEqual(result.text, "Alder Creek Design.")
            XCTAssertEqual(result.modelIdentifier, model)
            XCTAssertEqual(result.duration, 2)
            XCTAssertEqual(result.segments.first?.text, "Alder Creek Design.")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stagingURL.path).isEmpty)
        }
    }
}
