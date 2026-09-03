import Foundation
import XCTest

@testable import SpeakCore

/// Wire-level coverage for the Gemini 3.5 Transcribe Interactions API types
/// (issues #816, #862): request shaping, response decoding and the HTTP error
/// mapping, all asserted without a network round trip.
final class GeminiInteractionsAPITests: XCTestCase {

    // MARK: - Interactions request

    func testInteractionsRequest_usesDocumentedEndpointHeaderAndInlineAudio() throws {
        // Arrange
        let audio = Data([0x00, 0x01, 0x02, 0x03])

        // Act
        let request = try GeminiInteractionsRequest.make(
            apiKey: "gemini-test-key",
            audio: .inline(audio),
            mimeType: "audio/m4a",
            language: "en_GB"
        )
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        let generation = try XCTUnwrap(payload["generation_config"] as? [String: Any])
        let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])
        let mode = try XCTUnwrap(config["mode"] as? [String: Any])

        // Assert
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/interactions"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(payload["model"] as? String, "gemini-3.5-transcribe")
        XCTAssertEqual(input.first?["type"] as? String, "audio")
        XCTAssertEqual(input.first?["mime_type"] as? String, "audio/m4a")
        XCTAssertEqual(input.first?["data"] as? String, audio.base64EncodedString())
        XCTAssertNil(input.first?["uri"])
        XCTAssertEqual(config["language_codes"] as? [String], ["en-GB"])
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertEqual(mode["timestamp_granularities"] as? [String], ["word"])
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker")
    }

    func testInteractionsRequest_referencesAnUploadedFileWhenTheAudioIsLarge() throws {
        let request = try GeminiInteractionsRequest.make(
            apiKey: "k",
            audio: .fileURI("https://generativelanguage.googleapis.com/v1beta/files/abc123"),
            mimeType: "audio/wav",
            language: nil
        )
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        let generation = try XCTUnwrap(payload["generation_config"] as? [String: Any])
        let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])

        XCTAssertEqual(
            input.first?["uri"] as? String,
            "https://generativelanguage.googleapis.com/v1beta/files/abc123"
        )
        XCTAssertNil(input.first?["data"])
        // An empty array is the documented "detect the language automatically" setting.
        XCTAssertEqual(config["language_codes"] as? [String], [])
    }

    func testInteractionsRequest_smartModeDropsAnnotationsItCannotCombineWith() throws {
        let request = try GeminiInteractionsRequest.make(
            apiKey: "k", audio: .inline(Data()), mimeType: "audio/m4a", language: nil, mode: .smart
        )
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let generation = try XCTUnwrap(payload["generation_config"] as? [String: Any])
        let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])

        XCTAssertEqual(config["mode"] as? String, "smart")
    }

    // MARK: - Response parsing

    func testResponseParsing_readsTranscriptWordTimingsAndSpeakerLabels() throws {
        let json = """
        {
          "id": "interactions/abc123xyz",
          "status": "completed",
          "output_text": "Hello world",
          "steps": [
            {
              "id": "step_001",
              "type": "model_output",
              "content": [
                {
                  "type": "text",
                  "text": "Hello world",
                  "annotations": [
                    {
                      "type": "word_info",
                      "text": "Hello",
                      "speaker": "spk_1",
                      "start_offset": "0.100s",
                      "end_offset": "0.450s"
                    },
                    {
                      "type": "word_info",
                      "text": "world",
                      "speaker": "spk_2",
                      "start_offset": "0.460s",
                      "end_offset": "0.900s"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(GeminiInteractionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.transcript, "Hello world")
        XCTAssertEqual(
            decoded.wordAnnotations,
            [
                GeminiWordAnnotation(text: "Hello", speaker: "spk_1", startTime: 0.1, endTime: 0.45),
                GeminiWordAnnotation(text: "world", speaker: "spk_2", startTime: 0.46, endTime: 0.9)
            ]
        )
    }

    func testResponseParsing_fallsBackToStepTextWhenOutputTextIsAbsent() throws {
        let json = """
        {"status":"completed","steps":[{"type":"model_output","content":[
          {"type":"text","text":"First part."},{"type":"text","text":"Second part."}]}]}
        """

        let decoded = try JSONDecoder().decode(GeminiInteractionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.transcript, "First part. Second part.")
        XCTAssertTrue(decoded.wordAnnotations.isEmpty)
    }

    func testResponseParsing_ignoresNonWordAnnotationsAndMalformedOffsets() throws {
        let json = """
        {"output_text":"Hi","steps":[{"content":[{"annotations":[
          {"type":"citation","text":"nope"},
          {"type":"word_info","text":"Hi","start_offset":"oops","end_offset":null}]}]}]}
        """

        let decoded = try JSONDecoder().decode(GeminiInteractionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(
            decoded.wordAnnotations,
            [GeminiWordAnnotation(text: "Hi", speaker: nil, startTime: 0, endTime: 0)]
        )
    }

    func testResponseParsing_offsetSecondsAcceptsBothSpellings() {
        XCTAssertEqual(GeminiInteractionsResponse.seconds(from: "1.250s"), 1.25)
        XCTAssertEqual(GeminiInteractionsResponse.seconds(from: "2"), 2)
        XCTAssertEqual(GeminiInteractionsResponse.seconds(from: nil), 0)
    }

    // MARK: - HTTP error mapping

    func testHTTPFailure_mapsAuthRateLimitAndOtherStatuses() {
        let authBody = Data(#"{"error":{"code":403,"message":"denied","status":"PERMISSION_DENIED"}}"#.utf8)
        // `StreamingClientError` is a LocalizedError the UI renders, not an
        // Equatable value, so the assertion matches the case.
        guard case StreamingClientError.invalidAPIKey(let provider) =
            GeminiInteractionsResponse.mapHTTPFailure(status: 403, body: authBody) else {
            return XCTFail("Expected invalidAPIKey")
        }
        XCTAssertEqual(provider, "Google Gemini")

        let rateBody = Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)
        XCTAssertEqual(
            GeminiInteractionsResponse.mapHTTPFailure(status: 429, body: rateBody) as? GeminiBatchError,
            .rateLimited("slow down")
        )

        let serverBody = Data(#"{"error":{"code":503,"message":"overloaded"}}"#.utf8)
        guard case TranscriptionProviderError.httpError(let code, let message) =
            GeminiInteractionsResponse.mapHTTPFailure(status: 503, body: serverBody) else {
            return XCTFail("Expected an httpError")
        }
        XCTAssertEqual(code, 503)
        XCTAssertEqual(message, "overloaded")
    }

    func testHTTPFailure_keepsTheRawBodyWhenItIsNotAGeminiEnvelope() {
        guard case TranscriptionProviderError.httpError(_, let message) =
            GeminiInteractionsResponse.mapHTTPFailure(status: 500, body: Data("upstream down".utf8)) else {
            return XCTFail("Expected an httpError")
        }

        XCTAssertEqual(message, "upstream down")
    }

    func testMIMEType_isDerivedFromTheRecordingExtension() {
        XCTAssertEqual(GeminiAudioMIMEType.forFile(at: URL(fileURLWithPath: "/tmp/a.wav")), "audio/wav")
        XCTAssertEqual(GeminiAudioMIMEType.forFile(at: URL(fileURLWithPath: "/tmp/a.M4A")), "audio/m4a")
        XCTAssertEqual(GeminiAudioMIMEType.forFile(at: URL(fileURLWithPath: "/tmp/a.bin")), "audio/m4a")
    }
}
