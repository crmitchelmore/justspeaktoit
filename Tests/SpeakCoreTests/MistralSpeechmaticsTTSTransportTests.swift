import Foundation
import XCTest

@testable import SpeakCore

/// Covers what actually travels to Mistral and Speechmatics: endpoint, headers,
/// request body, response decoding and the classification of every documented
/// failure. Every call goes through a stubbed `URLProtocol`, so no provider
/// credit is spent.
final class MistralSpeechmaticsTTSTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TTSTransportMockURLProtocol.reset()
    }

    override func tearDown() {
        TTSTransportMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Mistral

    func testMistralSynthesize_postsVoxtralAndDecodesTheBase64Response() async throws {
        let audio = Data("ID3fake".utf8)
        TTSTransportStub.stub(
            statusCode: 200,
            body: Data(#"{"audio_data":"\#(audio.base64EncodedString())"}"#.utf8)
        )
        let api = MistralTTSAPI(session: TTSTransportStub.session())

        let decoded = try await api.synthesize(
            input: "Hello there",
            apiKey: "mist_test",
            request: MistralTTSRequest(voiceID: "mistral/019b2bd7-96e7-7219-8c0b-45a73da50088")
        )

        XCTAssertEqual(decoded, audio)
        let recorded = try XCTUnwrap(TTSTransportMockURLProtocol.lastRequest)
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.mistral.ai/v1/audio/speech")
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Authorization"), "Bearer mist_test")

        let body = try TTSTransportStub.body(of: recorded)
        XCTAssertEqual(body["model"] as? String, "voxtral-mini-tts-2603")
        XCTAssertEqual(body["voice_id"] as? String, "019b2bd7-96e7-7219-8c0b-45a73da50088")
        XCTAssertEqual(body["response_format"] as? String, "mp3")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testMistralSynthesize_refusesARequestWithNoVoice() async {
        TTSTransportStub.stub(statusCode: 200, body: Data("{}".utf8))
        let api = MistralTTSAPI(session: TTSTransportStub.session())

        await XCTAssertTTSThrowsAsync(
            try await api.synthesize(
                input: "Hello there",
                apiKey: "mist_test",
                request: MistralTTSRequest(voiceID: "")
            )
        ) { error in
            XCTAssertEqual(error as? MistralTTSAPIError, .voiceRequired)
        }
        XCTAssertNil(TTSTransportMockURLProtocol.lastRequest)
    }

    func testMistralVoiceListing_acceptsEveryUndocumentedEnvelopeShape() throws {
        let voice = #"{"id":"abc","name":"Ada","gender":"female","languages":["en","fr"]}"#
        for payload in [
            Data("{\"data\":[\(voice)]}".utf8),
            Data("{\"voices\":[\(voice)]}".utf8),
            Data("[\(voice)]".utf8)
        ] {
            let voices = try MistralTTSAPI.decodeVoices(from: payload)
            XCTAssertEqual(voices.map(\.id), ["abc"])
            XCTAssertEqual(voices.first?.providerVoiceID, "mistral/abc")
        }
    }

    func testMistralErrors_classifyAuthQuotaAndTheOverloadedForbidden() {
        let auth = MistralTTSAPI.error(
            from: Data(#"{"object":"error","message":"Unauthorized","type":"authentication_error"}"#.utf8),
            statusCode: 401
        )
        guard case .unauthorized = auth else { return XCTFail("expected unauthorized, got \(auth)") }

        let forbidden = MistralTTSAPI.error(
            from: Data(#"{"object":"error","message":"moderation","type":"invalid_request_error"}"#.utf8),
            statusCode: 403
        )
        guard case .forbidden = forbidden else {
            return XCTFail("expected forbidden, got \(forbidden)")
        }

        let limited = MistralTTSAPI.error(from: Data("{}".utf8), statusCode: 429)
        guard case .rateLimited = limited else {
            return XCTFail("expected rate limiting, got \(limited)")
        }
    }

    // MARK: - Speechmatics

    func testSpeechmaticsSynthesize_putsTheVoiceInThePathAndTheFormatInTheQuery() async throws {
        TTSTransportStub.stub(statusCode: 200, body: Data("RIFFfake".utf8))
        let api = SpeechmaticsTTSAPI(session: TTSTransportStub.session())

        _ = try await api.synthesize(
            text: "Hello there",
            apiKey: "sm_test",
            request: SpeechmaticsTTSRequest(voiceID: "speechmatics/theo")
        )

        let recorded = try XCTUnwrap(TTSTransportMockURLProtocol.lastRequest)
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(recorded.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.host, "preview.tts.speechmatics.com")
        XCTAssertEqual(components.path, "/generate/theo")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "output_format" })?.value,
            "wav_16000"
        )
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Authorization"), "Bearer sm_test")

        let body = try TTSTransportStub.body(of: recorded)
        XCTAssertEqual(body["text"] as? String, "Hello there")
        XCTAssertEqual(body.count, 1, "the body carries the text and nothing else")
    }

    func testSpeechmaticsCatalogue_shipsTheFourDocumentedVoicesAndFallsBack() {
        XCTAssertEqual(SpeechmaticsTTSCatalog.voices.map(\.id), ["sarah", "theo", "megan", "jack"])
        XCTAssertEqual(
            SpeechmaticsTTSCatalog.resolvedAPIVoiceID(forVoiceID: "speechmatics/nobody"),
            "sarah"
        )
    }

    func testSpeechmaticsErrors_surviveTheHTMLBodyTheEdgeProxyReturns() {
        let html = Data("<html><head><title>401 Authorization Required</title></head></html>".utf8)
        let error = SpeechmaticsTTSAPI.error(from: html, statusCode: 401)
        guard case .unauthorized(_, let message) = error else {
            return XCTFail("expected unauthorized, got \(error)")
        }
        // Nothing from the body is echoed: it is not JSON and could carry anything.
        XCTAssertEqual(message, "Unknown Speechmatics error")
        XCTAssertFalse(message.contains("<html>"))
    }

    func testSpeechmaticsSynthesize_rejectsEmptyTextAndReportsQuotaExhaustion() async {
        TTSTransportStub.stub(statusCode: 200, body: Data("RIFFfake".utf8))
        let api = SpeechmaticsTTSAPI(session: TTSTransportStub.session())

        await XCTAssertTTSThrowsAsync(
            try await api.synthesize(
                text: "",
                apiKey: "sm_test",
                request: SpeechmaticsTTSRequest(voiceID: "speechmatics/sarah")
            )
        ) { error in
            XCTAssertEqual(error as? SpeechmaticsTTSAPIError, .emptyText)
        }

        let quota = SpeechmaticsTTSAPI.error(from: Data("{}".utf8), statusCode: 402)
        guard case .quotaExceeded = quota else {
            return XCTFail("expected quota exhaustion, got \(quota)")
        }
    }
}
