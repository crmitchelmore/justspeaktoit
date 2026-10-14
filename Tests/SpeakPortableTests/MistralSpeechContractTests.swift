import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class MistralSpeechContractTests: DeepgramSpeechStubTestCase {
    private let voiceID = "019b2bd7-96e7-7219-8c0b-45a73da50088"

    func testCanonicalSpeechRequest_PreservesMacDefaultsAndExplicitWAVWithoutInventedControls() throws {
        let request = try MistralTTSAPI.synthesisRequest(
            input: "Synthetic speech.", apiKey: "synthetic-key",
            request: MistralTTSRequest(voiceID: "mistral/\(voiceID)", responseFormat: .wav))
        XCTAssertEqual(request.url, MistralTTSAPI.speechEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, MistralTTSCatalog.defaultModel.rawValue)
        XCTAssertEqual(body["voice_id"] as? String, voiceID)
        XCTAssertEqual(body["response_format"] as? String, MistralTTSResponseFormat.wav.rawValue)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["speed"])
        XCTAssertNil(body["pitch"])
        XCTAssertNil(body["sample_rate"])
        XCTAssertThrowsError(try MistralTTSAPI.synthesisRequest(
            input: " ", apiKey: "synthetic-key", request: MistralTTSRequest(voiceID: voiceID)))
        XCTAssertThrowsError(try MistralTTSAPI.synthesisRequest(
            input: "Synthetic", apiKey: "synthetic-key", request: MistralTTSRequest(voiceID: "")))
    }

    func testCanonicalSpeechTransport_UsesTheSameBase64DecoderAndRejectsMissingOrMalformedAudio() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        let response = try JSONSerialization.data(withJSONObject: ["audio_data": audio.base64EncodedString()])
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), response) }
        let received = try await MistralTTSAPI(session: session).synthesize(
            input: "Synthetic input.", apiKey: "synthetic-key",
            request: MistralTTSRequest(voiceID: voiceID, responseFormat: .wav))
        XCTAssertEqual(received, audio)
        XCTAssertThrowsError(try MistralTTSAPI.decodedAudio(from: Data(#"{"audio_data":""}"#.utf8)))
        XCTAssertThrowsError(try MistralTTSAPI.decodedAudio(from: Data(#"{"audio_data":"!invalid!"}"#.utf8)))
        XCTAssertThrowsError(try MistralTTSAPI.decodedAudio(from: Data(#"{"not_audio":"private"}"#.utf8)))
    }

    func testCanonicalListingRequest_BoundsOffsetsAndRejectsUnknownEnvelopesRatherThanEmptySuccess() throws {
        let request = try MistralTTSAPI.voiceListRequest(
            apiKey: "synthetic-key", presetsOnly: true, offset: MistralTTSAPI.voicePageSize)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "limit", value: String(MistralTTSAPI.voicePageSize)),
            URLQueryItem(name: "offset", value: String(MistralTTSAPI.voicePageSize)),
            URLQueryItem(name: "type", value: "preset")
        ])
        XCTAssertThrowsError(try MistralTTSAPI.voiceListRequest(apiKey: "synthetic-key", offset: -1))
        XCTAssertThrowsError(try MistralTTSAPI.voiceListRequest(
            apiKey: "synthetic-key", offset: MistralTTSAPI.voicePageSize * MistralTTSAPI.maxVoicePages))
        XCTAssertEqual(try MistralTTSAPI.decodeVoices(from: Data(#"{"items":[]}"#.utf8)), [])
        XCTAssertThrowsError(try MistralTTSAPI.decodeVoices(from: Data(#"{"unknown":[]}"#.utf8)))
    }

    func testMacChunkGuidance_PreservesUnicodeAt1799_1800_1801AndMixedWhitespaceBoundaries() {
        for count in [1_799, 1_800, 1_801] {
            let text = String(repeating: "e\u{301}", count: count)
            let chunks = TTSTextChunker.chunks(text, maximumCharacters: MistralTTSAPI.maxInputCharacters)
            XCTAssertEqual(chunks.count, count <= MistralTTSAPI.maxInputCharacters ? 1 : 2)
            XCTAssertEqual(chunks.joined(), text)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= MistralTTSAPI.maxInputCharacters })
        }
        let text = " \t" + String(repeating: "Synthetic cafe\u{301}. \r\n", count: 240)
            + "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} end. \n"
        let chunks = TTSTextChunker.chunks(text, maximumCharacters: MistralTTSAPI.maxInputCharacters)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= MistralTTSAPI.maxInputCharacters })
    }
}
