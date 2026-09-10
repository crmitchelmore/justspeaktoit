import Foundation
import XCTest

@testable import SpeakCore

/// Covers xAI speech generation: the REST request shape, the voice catalogue
/// and listing, the streaming protocol used for progressive playback, and the
/// failure classification.
final class XAITTSTransportTests: XCTestCase {
    override func tearDown() {
        TTSTransportMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Catalogue

    /// Only the identifiers the capability page names literally ship as
    /// presets; the rest come from the account listing, because an
    /// unrecognised `voice_id` is an HTTP 404 rather than a fallback.
    func testCatalogue_shipsOnlyTheDocumentedPresetVoices() {
        XCTAssertEqual(XAITTSCatalog.voices.map(\.id), ["eve", "ara"])
        XCTAssertEqual(XAITTSCatalog.defaultVoice.id, XAITTSCatalog.defaultVoiceID)
        XCTAssertEqual(XAITTSCatalog.voices.map(\.providerVoiceID), ["xai/eve", "xai/ara"])
    }

    func testVoiceResolution_isCaseInsensitiveAndPassesAccountVoicesThrough() {
        XCTAssertEqual(XAITTSCatalog.apiVoiceID(forVoiceID: "xai/eve"), "eve")
        XCTAssertEqual(XAITTSCatalog.voice(forID: "xai/EVE")?.id, "eve")
        XCTAssertEqual(XAITTSCatalog.resolvedAPIVoiceID(forVoiceID: "xai/Eve"), "eve")
        // An identifier the presets do not know is very likely an account
        // voice; rewriting it to `eve` would speak in the wrong voice.
        XCTAssertEqual(XAITTSCatalog.resolvedAPIVoiceID(forVoiceID: "xai/nlbqfwie"), "nlbqfwie")
        XCTAssertEqual(XAITTSCatalog.resolvedAPIVoiceID(forVoiceID: "  "), "eve")
    }

    /// `language` is a required field, so an unrecognised selection becomes
    /// `auto` — which is what xAI provides for exactly this case — rather than
    /// being omitted and rejected.
    func testLanguageResolution_prefersTheExactDocumentedTag() {
        XCTAssertEqual(XAITTSCatalog.languageTag(for: "pt_BR"), "pt-BR")
        XCTAssertEqual(XAITTSCatalog.languageTag(for: "es-mx"), "es-MX")
        XCTAssertEqual(XAITTSCatalog.languageTag(for: "en_GB"), "en")
        XCTAssertEqual(XAITTSCatalog.languageTag(for: "cy_GB"), "auto")
        XCTAssertEqual(XAITTSCatalog.languageTag(for: nil), "auto")
        XCTAssertEqual(XAITTSCatalog.languageTag(for: "Automatic"), "auto")
    }

    // MARK: - REST request

    func testRequestBody_carriesTheDocumentedFieldsAndNoModel() throws {
        let request = XAITTSRequest(
            voiceID: "xai/ara", language: "pt_BR", codec: .mp3, speed: 1.2
        )
        let body = request.jsonBody(text: "Hello")
        let outputFormat = try XCTUnwrap(body["output_format"] as? [String: Any])

        XCTAssertEqual(body["text"] as? String, "Hello")
        XCTAssertEqual(body["voice_id"] as? String, "ara")
        XCTAssertEqual(body["language"] as? String, "pt-BR")
        XCTAssertEqual(body["speed"] as? Double, 1.2)
        XCTAssertEqual(outputFormat["codec"] as? String, "mp3")
        XCTAssertEqual(outputFormat["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(outputFormat["bit_rate"] as? Int, 128_000)
        // xAI publishes no speech model identifier, so none is sent.
        XCTAssertNil(body["model"])
    }

    func testRequest_clampsToTheDocumentedRangesAndDropsBitRateOffMP3() throws {
        let fast = XAITTSRequest(voiceID: "xai/eve", language: "en", speed: 9)
        let slow = XAITTSRequest(voiceID: "xai/eve", language: "en", speed: 0.1)
        XCTAssertEqual(fast.speed, XAITTSAPI.speedRange.upperBound)
        XCTAssertEqual(slow.speed, XAITTSAPI.speedRange.lowerBound)

        let odd = XAITTSRequest(
            voiceID: "xai/eve", language: "en", codec: .wav, sampleRate: 12_345, bitRate: 7
        )
        XCTAssertEqual(odd.sampleRate, XAITTSAPI.defaultSampleRate)
        let format = try XCTUnwrap(odd.jsonBody(text: "x")["output_format"] as? [String: Any])
        // `bit_rate` is MP3-only; sending it with WAV would be a field the
        // service has no use for.
        XCTAssertNil(format["bit_rate"])
    }

    func testSynthesize_postsToTheSpeechEndpointWithABearerHeader() async throws {
        let session = TTSTransportStub.session()
        TTSTransportStub.stub(statusCode: 200, body: Data(repeating: 0x1, count: 16))

        let audio = try await XAITTSAPI(session: session).synthesize(
            text: "Hello",
            apiKey: "fixture",
            request: XAITTSRequest(voiceID: "xai/eve", language: "en")
        )
        let request = try XCTUnwrap(TTSTransportMockURLProtocol.lastRequest)

        XCTAssertEqual(audio.count, 16)
        XCTAssertEqual(request.url, XAITTSAPI.speechEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(
            try TTSTransportStub.body(of: request)["voice_id"] as? String,
            "eve"
        )
    }

    func testSynthesize_rejectsEmptyAndOverlongTextBeforeSpendingARequest() async {
        let session = TTSTransportStub.session()
        TTSTransportStub.stub(statusCode: 200, body: Data([0x1]))
        let api = XAITTSAPI(session: session)
        let request = XAITTSRequest(voiceID: "xai/eve", language: "en")

        for blank in ["", "   ", "\n"] {
            await XCTAssertTTSThrowsAsync(
                try await api.synthesize(text: blank, apiKey: "fixture", request: request)
            ) { error in
                XCTAssertEqual(error as? XAITTSAPIError, .emptyText)
            }
        }
        let long = String(repeating: "a", count: XAITTSAPI.maximumTextCharacters + 1)
        await XCTAssertTTSThrowsAsync(
            try await api.synthesize(text: long, apiKey: "fixture", request: request)
        ) { error in
            XCTAssertEqual(
                error as? XAITTSAPIError,
                .textTooLong(
                    limit: XAITTSAPI.maximumTextCharacters,
                    characterCount: XAITTSAPI.maximumTextCharacters + 1
                )
            )
        }
    }

    func testSynthesize_classifiesAuthQuotaVoiceAndRateLimitFailures() async {
        let session = TTSTransportStub.session()
        let api = XAITTSAPI(session: session)
        let request = XAITTSRequest(voiceID: "xai/eve", language: "en")
        let expected: [Int: XAITTSAPIError] = [
            400: .badRequest(message: "bad"),
            401: .unauthorized(statusCode: 401, message: "bad"),
            403: .unauthorized(statusCode: 403, message: "bad"),
            402: .quotaExceeded(message: "bad"),
            404: .voiceNotFound(message: "bad"),
            429: .rateLimited(message: "bad"),
            503: .httpError(statusCode: 503, message: "bad")
        ]
        for (statusCode, expectation) in expected {
            TTSTransportStub.stub(statusCode: statusCode, body: Data(#"{"error":"bad"}"#.utf8))
            await XCTAssertTTSThrowsAsync(
                try await api.synthesize(text: "Hello", apiKey: "fixture", request: request)
            ) { error in
                XCTAssertEqual(error as? XAITTSAPIError, expectation)
            }
        }
        // A 2xx with no bytes is not silence, it is a broken response.
        TTSTransportStub.stub(statusCode: 200, body: Data())
        await XCTAssertTTSThrowsAsync(
            try await api.synthesize(text: "Hello", apiKey: "fixture", request: request)
        ) { error in
            XCTAssertEqual(error as? XAITTSAPIError, .invalidResponse)
        }
    }

    func testListVoices_readsTheAccountListingAndItsOptionalLanguage() async throws {
        let session = TTSTransportStub.session()
        TTSTransportStub.stub(
            statusCode: 200,
            body: Data("""
            {"voices":[{"voice_id":"eve","name":"Eve","language":"en"},
                       {"voice_id":"nlbqfwie","name":"Custom","language":null}]}
            """.utf8)
        )
        let voices = try await XAITTSAPI(session: session).listVoices(apiKey: "fixture")
        let request = try XCTUnwrap(TTSTransportMockURLProtocol.lastRequest)

        XCTAssertEqual(request.url, XAITTSAPI.voicesEndpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(voices.map(\.id), ["eve", "nlbqfwie"])
        XCTAssertEqual(voices.last?.providerVoiceID, "xai/nlbqfwie")
        XCTAssertNil(voices.last?.language)
    }

    func testDecodeVoices_reportsAResponseItCannotRead() {
        XCTAssertThrowsError(try XAITTSAPI.decodeVoices(Data(#"{"unexpected":true}"#.utf8))) { error in
            XCTAssertEqual(error as? XAITTSAPIError, .invalidResponse)
        }
    }

    // MARK: - Streaming protocol (progressive playback)

    func testStreamURL_usesPCMSoSamplesCanPlayAsTheyArrive() throws {
        let request = XAITTSRequest(
            voiceID: "xai/ara", language: "en", codec: .pcm, sampleRate: 24_000, speed: 1.1
        )
        let url = try XCTUnwrap(XAITTSRealtime.webSocketURL(request: request))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.x.ai")
        XCTAssertEqual(components.path, "/v1/tts")
        XCTAssertEqual(items.first { $0.name == "codec" }?.value, "pcm")
        XCTAssertEqual(items.first { $0.name == "voice" }?.value, "ara")
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "en")
        XCTAssertEqual(items.first { $0.name == "sample_rate" }?.value, "24000")
        XCTAssertEqual(items.first { $0.name == "optimize_streaming_latency" }?.value, "1")
        // MP3 bit rate has no meaning for a PCM stream.
        XCTAssertNil(items.first { $0.name == "bit_rate" })
    }

    func testClientFrames_matchTheDocumentedTextDeltaAndDoneShapes() throws {
        let delta = try XCTUnwrap(XAITTSRealtime.textDeltaJSON("Hello \"there\""))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(delta.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "text.delta")
        XCTAssertEqual(object["delta"] as? String, "Hello \"there\"")
        XCTAssertEqual(XAITTSRealtime.textDoneJSON, #"{"type":"text.done"}"#)
        XCTAssertEqual(XAITTSRealtime.textClearJSON, #"{"type":"text.clear"}"#)
    }

    func testServerFrames_decodeAudioDeltasDoneClearAndErrors() throws {
        let audio = Data([0x11, 0x22, 0x33, 0x44])
        let delta = #"{"type":"audio.delta","delta":"\#(audio.base64EncodedString())"}"#
        XCTAssertEqual(XAITTSRealtimeEvent(frame: Data(delta.utf8)), .audio(audio))
        XCTAssertEqual(
            XAITTSRealtimeEvent(frame: Data(#"{"type":"audio.done","trace_id":"t"}"#.utf8)),
            .done
        )
        XCTAssertEqual(
            XAITTSRealtimeEvent(frame: Data(#"{"type":"audio.clear"}"#.utf8)),
            .cleared
        )
        XCTAssertEqual(
            XAITTSRealtimeEvent(frame: Data(#"{"type":"session.updated","replace":{}}"#.utf8)),
            .sessionUpdated
        )
        XCTAssertEqual(
            XAITTSRealtimeEvent(frame: Data(#"{"type":"error","message":"quota"}"#.utf8)),
            .failure(message: "quota")
        )
        // A chunk that is not valid base64 is a protocol failure: playing on
        // would drop a span of speech and still report success.
        XCTAssertEqual(
            XAITTSRealtimeEvent(frame: Data(#"{"type":"audio.delta","delta":"!!!not base64"}"#.utf8)),
            .failure(message: "xAI sent an audio chunk that is not valid base64")
        )
        // An unknown frame is ignored rather than ending the utterance.
        XCTAssertNil(XAITTSRealtimeEvent(frame: Data(#"{"type":"ping"}"#.utf8)))
        XCTAssertNil(XAITTSRealtimeEvent(frame: Data("not json".utf8)))
    }

    func testProgressiveText_isSplitIntoUtterancesInsideTheDocumentedMaximum() {
        let chunkSize = XAITTSRealtime.textChunkCharacters
        let maximum = XAITTSAPI.maximumTextCharacters
        // Two and a half utterances worth of delta frames.
        let chunkCount = (maximum / chunkSize) * 2 + 5
        let chunks = Array(repeating: String(repeating: "a", count: chunkSize), count: chunkCount)

        let utterances = XAITTSRealtime.utterances(from: chunks)
        XCTAssertGreaterThan(utterances.count, 1, "a long document cannot be one utterance")
        for utterance in utterances {
            let characters = utterance.reduce(0) { $0 + $1.count }
            XCTAssertLessThanOrEqual(characters, maximum)
        }
        // Nothing is dropped or reordered.
        XCTAssertEqual(utterances.flatMap { $0 }, chunks)
    }

    func testProgressiveText_keepsAShortDocumentAsOneUtterance() {
        let chunks = ["Hello there.", "How are you?"]
        XCTAssertEqual(XAITTSRealtime.utterances(from: chunks), [chunks])
        XCTAssertTrue(XAITTSRealtime.utterances(from: []).isEmpty)
    }

    /// Progressive playback schedules the samples directly, so the finished
    /// file has to be given the RIFF header the players need.
    func testProgressiveAudio_becomesAPlayableWAVAtTheStreamSampleRate() throws {
        let pcm = Data(repeating: 0x7F, count: 48)
        let wav = try XCTUnwrap(
            PCMWaveWriter.wavData(pcm: pcm, sampleRate: XAITTSAPI.defaultSampleRate)
        )

        XCTAssertEqual(wav.count, pcm.count + 44)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav[8..<12], Data("WAVE".utf8))
    }
}
