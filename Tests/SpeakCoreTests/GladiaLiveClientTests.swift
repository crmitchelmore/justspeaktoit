import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Ports of the dedicated Mac wire assertions. The old tests stay in place
/// until the controller fold has qualified; no request is sent here.
final class GladiaLiveClientTests: XCTestCase {
    func testInitRequest_usesDocumentedEndpointHeadersAndPCM16Config() throws {
        let request = try initRequest(language: "en_GB")
        let payload = try body(request)
        let languages = try XCTUnwrap(payload["language_config"] as? [String: Any])
        XCTAssertEqual(request.url?.absoluteString, "https://api.gladia.io/v2/live")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "test-gladia-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(payload["model"] as? String, "solaria-1")
        XCTAssertEqual(payload["encoding"] as? String, "wav/pcm")
        XCTAssertEqual(payload["bit_depth"] as? Int, 16)
        XCTAssertEqual(payload["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(payload["channels"] as? Int, 1)
        XCTAssertEqual(languages["languages"] as? [String], ["en"])
        XCTAssertEqual(languages["code_switching"] as? Bool, false)
        XCTAssertEqual(payload["messages_config"] as? [String: Bool], [
            "receive_partial_transcripts": true, "receive_final_transcripts": true,
            "receive_speech_events": false, "receive_pre_processing_events": false,
            "receive_realtime_processing_events": false, "receive_post_processing_events": false,
            "receive_acknowledgments": false, "receive_errors": true, "receive_lifecycle_events": true
        ])
    }

    func testInitRequest_usesTheCanonicalGladiaLanguageMapping() throws {
        let automatic = TranscriptionLanguageCatalog.automaticIdentifier
        for option in TranscriptionLanguageCatalog.options where option.id != automatic {
            let config = try languageConfig(option.id)
            XCTAssertEqual(config["languages"] as? [String], [option.id.localeLanguageCode], option.id)
            XCTAssertEqual(config["languages"] as? [String], GladiaLive.languageCode(for: option.id).map { [$0] })
            XCTAssertEqual(config["code_switching"] as? Bool, false, option.id)
        }
        for language in [automatic, nil, "yue_HK", "iw_IL"] as [String?] {
            let config = try languageConfig(language)
            XCTAssertEqual(config["languages"] as? [String], [], String(describing: language))
            XCTAssertEqual(config["code_switching"] as? Bool, true, String(describing: language))
        }
    }

    func testStopRecordingMessage_usesDocumentedShape() {
        XCTAssertEqual(GladiaLiveProtocol.stopRecordingJSON, #"{"type":"stop_recording"}"#)
    }

    func testTranscriptEvent_parsesPartialTranscript() {
        let frame = #"{"type":"transcript","data":{"id":"00-00000011","is_final":false,"#
            + #""utterance":{"text":"Hello wor","confidence":0.91,"language":"en"}}}"#
        XCTAssertEqual(GladiaLiveProtocol.event(from: .text(frame)),
                       .transcript(utteranceID: "00-00000011", text: "Hello wor", isFinal: false, confidence: 0.91))
    }

    func testTranscriptEvent_parsesFinalTranscript() {
        let frame = #"{"type":"transcript","data":{"id":"00-00000011","is_final":true,"#
            + #""utterance":{"text":"Hello world.","confidence":0.98}}}"#
        XCTAssertEqual(GladiaLiveProtocol.event(from: .text(frame)),
                       .transcript(utteranceID: "00-00000011", text: "Hello world.", isFinal: true, confidence: 0.98))
    }

    func testTranscriptEvent_ignoresNonTranscriptAndEmptyText() {
        XCTAssertNil(GladiaLiveProtocol.event(from: .text(#"{"type":"speech_start","data":{}}"#)))
        // The current Core decoder preserves the blank event shape; its live
        // delivery path ignores it. See the actual-client snapshot regression.
        let blank = #"{"type":"transcript","data":{"is_final":true,"utterance":{"text":""}}}"#
        XCTAssertEqual(GladiaLiveProtocol.event(from: .text(blank)),
                       .transcript(utteranceID: nil, text: "", isFinal: true))
    }

    private func initRequest(language: String?) throws -> URLRequest {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "gladia/solaria-1-streaming"))
        let client = try XCTUnwrap(LiveTranscriptionClientFactory.makeClient(
            for: route, apiKey: "test-gladia-key", language: language
        ) as? GladiaLiveClient)
        let payload = try XCTUnwrap(GladiaLiveProtocol.initBody(
            model: client.model, language: client.language, sampleRate: client.sampleRate
        ))
        return GladiaLiveProtocol.initRequest(endpoint: client.endpoint, apiKey: client.apiKey, body: payload)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func languageConfig(_ language: String?) throws -> [String: Any] {
        try XCTUnwrap(body(initRequest(language: language))["language_config"] as? [String: Any])
    }
}
