import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Scribe v2 Medical shares the Create transcript endpoint with Scribe v2, so
/// the only thing that differs on the wire is the bare `model_id`.
final class ElevenLabsScribeMedicalTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testTranscribeFile_sendsMedicalModelID_forScribeV2Medical() async throws {
        StubURLProtocol.handler = { request in
            .ok(Data(#"{"text":"blood pressure","language_code":"en","words":null}"#.utf8),
                url: try XCTUnwrap(request.url))
        }
        let provider = ElevenLabsTranscriptionProvider(session: StubURLProtocol.makeSession())
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe_medical_\(UUID().uuidString).m4a")
        try Data("fakeaudiodata".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // try? because AVURLAsset cannot read a duration from the synthetic audio.
        _ = try? await provider.transcribeFile(
            at: audioURL,
            apiKey: "test-key",
            model: ModelCatalog.elevenLabsScribeV2MedicalBatchID,
            language: nil
        )

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text")
        let body = String(data: StubURLProtocol.body(of: request), encoding: .utf8) ?? ""
        XCTAssertTrue(
            body.contains("name=\"model_id\"\r\n\r\nscribe_v2_medical\r\n"),
            "ElevenLabs expects the bare scribe_v2_medical id in the model_id form field"
        )
    }
}
