import Foundation
import XCTest

@testable import SpeakCore

/// Covers what actually travels to Groq and Gemini: endpoint, headers, request
/// body, response decoding and the classification of every documented failure.
/// Every call goes through a stubbed `URLProtocol`, so no provider credit is
/// spent.
final class GroqGeminiTTSTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TTSTransportMockURLProtocol.reset()
    }

    override func tearDown() {
        TTSTransportMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Groq

    func testGroqSynthesize_postsToTheSpeechEndpointWithTheOrpheusModelAndVoice() async throws {
        TTSTransportStub.stub(statusCode: 200, body: Data("RIFFfake".utf8))
        let api = GroqTTSAPI(session: TTSTransportStub.session())

        _ = try await api.synthesize(
            input: "Hello there",
            apiKey: "gsk_test",
            request: GroqTTSRequest(voiceID: "groq/orpheus-v1-english/austin")
        )

        let recorded = try XCTUnwrap(TTSTransportMockURLProtocol.lastRequest)
        XCTAssertEqual(
            recorded.url?.absoluteString,
            "https://api.groq.com/openai/v1/audio/speech"
        )
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Authorization"), "Bearer gsk_test")

        let body = try TTSTransportStub.body(of: recorded)
        XCTAssertEqual(body["model"] as? String, "canopylabs/orpheus-v1-english")
        XCTAssertEqual(body["voice"] as? String, "austin")
        XCTAssertEqual(body["input"] as? String, "Hello there")
        XCTAssertEqual(body["response_format"] as? String, "wav")
    }

    func testGroqRequest_takesTheModelFromTheVoiceAndFallsBackToTheDefault() {
        XCTAssertEqual(
            GroqTTSRequest(voiceID: "groq/orpheus-arabic-saudi/lulwa").model,
            .orpheusArabicSaudi
        )
        // A voice Groq does not host would be a 400, so it resolves to the default.
        let unknown = GroqTTSRequest(voiceID: "groq/orpheus-v1-english/tara")
        XCTAssertEqual(unknown.voiceID, GroqTTSCatalog.defaultVoice.apiVoiceID)
        XCTAssertEqual(unknown.model, .orpheusEnglish)
    }

    func testGroqCatalogue_excludesTheRetiredPlayAIIdentifiers() {
        let modelIDs = GroqTTSCatalog.models.map(\.rawValue)
        XCTAssertFalse(modelIDs.contains("playai-tts"))
        XCTAssertFalse(modelIDs.contains("playai-tts-arabic"))
        XCTAssertEqual(GroqTTSCatalog.voices.count, 12)
        XCTAssertTrue(GroqTTSCatalog.voices.allSatisfy { $0.id == $0.id.lowercased() })
    }

    func testGroqSynthesize_rejectsEmptyTextBeforeTouchingTheNetwork() async {
        TTSTransportStub.stub(statusCode: 200, body: Data("RIFFfake".utf8))
        let api = GroqTTSAPI(session: TTSTransportStub.session())

        await XCTAssertTTSThrowsAsync(
            try await api.synthesize(
                input: "   \n ",
                apiKey: "gsk_test",
                request: GroqTTSRequest(voiceID: GroqTTSCatalog.defaultVoice.providerVoiceID)
            )
        ) { error in
            XCTAssertEqual(error as? GroqTTSAPIError, .emptyText)
        }
        XCTAssertNil(TTSTransportMockURLProtocol.lastRequest)
    }

    func testGroqErrors_separateTheTermsGateFromABadKey() {
        let terms = GroqTTSAPI.error(
            from: Data(#"{"error":{"message":"requires terms acceptance","code":"model_terms_required"}}"#.utf8),
            statusCode: 400
        )
        guard case .modelTermsRequired = terms else {
            return XCTFail("expected a terms gate, got \(terms)")
        }

        let blocked = GroqTTSAPI.error(
            from: Data(#"{"error":{"message":"spend limit","code":"blocked_api_access"}}"#.utf8),
            statusCode: 400
        )
        guard case .accessBlocked = blocked else {
            return XCTFail("expected an access block, got \(blocked)")
        }

        let unauthorized = GroqTTSAPI.error(
            from: Data(#"{"error":{"message":"Invalid API Key","code":"invalid_api_key"}}"#.utf8),
            statusCode: 401
        )
        guard case .unauthorized = unauthorized else {
            return XCTFail("expected unauthorized, got \(unauthorized)")
        }

        let limited = GroqTTSAPI.error(
            from: Data(#"{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}"#.utf8),
            statusCode: 429
        )
        guard case .rateLimited = limited else {
            return XCTFail("expected rate limiting, got \(limited)")
        }
    }

    func testGroqSynthesize_stopsWhenTheTaskIsCancelled() async throws {
        TTSTransportStub.stub(statusCode: 200, body: Data("RIFFfake".utf8))
        let api = GroqTTSAPI(session: TTSTransportStub.session())

        let task = Task {
            try await api.synthesize(
                input: "Hello there",
                apiKey: "gsk_test",
                request: GroqTTSRequest(voiceID: GroqTTSCatalog.defaultVoice.providerVoiceID)
            )
        }
        task.cancel()

        await XCTAssertTTSThrowsAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Gemini

    func testGeminiSynthesize_postsTheInteractionsBodyWithTheVoiceAndSampleRate() async throws {
        TTSTransportStub.stub(statusCode: 200, body: TTSTransportStub.geminiAudioResponse())
        let api = GeminiTTSAPI(session: TTSTransportStub.session())

        _ = try await api.synthesize(
            input: "Hello there",
            apiKey: "AIza-test",
            request: GeminiTTSRequest(voiceID: "google/Kore", languageIdentifier: "en_GB")
        )

        let recorded = try XCTUnwrap(TTSTransportMockURLProtocol.lastRequest)
        XCTAssertEqual(
            recorded.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/interactions"
        )
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")

        let body = try TTSTransportStub.body(of: recorded)
        XCTAssertEqual(body["model"] as? String, "gemini-3.1-flash-tts-preview")
        XCTAssertEqual(body["input"] as? String, "Hello there")

        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "audio")
        XCTAssertEqual(responseFormat["sample_rate"] as? Int, 24_000)

        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let speech = try XCTUnwrap(generation["speech_config"] as? [[String: Any]])
        XCTAssertEqual(speech.first?["voice"] as? String, "Kore")
        XCTAssertEqual(speech.first?["language"] as? String, "en-GB")
    }

    func testGeminiRequest_omitsTheLanguageWhenTheUserHasNotChosenARegion() {
        XCTAssertNil(GeminiTTSRequest(voiceID: "google/Kore", languageIdentifier: nil).languageTag)
        XCTAssertNil(
            GeminiTTSRequest(voiceID: "google/Kore", languageIdentifier: "automatic").languageTag
        )
    }

    func testGeminiCatalogue_shipsTheThirtyDocumentedVoicesAndOneRunnableModel() {
        XCTAssertEqual(GeminiTTSCatalog.voices.count, 30)
        XCTAssertEqual(GeminiTTSCatalog.models.map(\.rawValue), ["gemini-3.1-flash-tts-preview"])
        // A stored lower-cased name still resolves; an unknown one falls back.
        XCTAssertEqual(GeminiTTSCatalog.resolvedVoice(forID: "google/kore").id, "Kore")
        XCTAssertEqual(
            GeminiTTSCatalog.resolvedVoice(forID: "google/nonexistent").id,
            GeminiTTSCatalog.defaultVoice.id
        )
    }

    func testGeminiAudio_wrapsHeaderlessPCMAndPassesAContainerThrough() throws {
        let pcm = Data(repeating: 0x01, count: 64)
        let raw = GeminiTTSAudio(data: pcm, mimeType: "audio/l16", sampleRate: 24_000, channels: 1)
        let wrapped = try XCTUnwrap(raw.playableData)
        XCTAssertEqual(wrapped.count, pcm.count + 44)
        XCTAssertEqual(String(bytes: wrapped.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: wrapped[8..<12], encoding: .ascii), "WAVE")

        let contained = GeminiTTSAudio(
            data: Data("RIFFalready".utf8),
            mimeType: "audio/wav",
            sampleRate: 24_000,
            channels: 1
        )
        XCTAssertEqual(contained.playableData, contained.data)
    }

    func testGeminiAudio_rejectsPCMMetadataAWAVHeaderCannotDescribe() {
        // `sample_rate` and `channels` are provider-supplied, so a hostile or
        // corrupt value must produce an error rather than trap the writer.
        for (rate, channels) in [(-1, 1), (0, 1), (Int.max, 1), (24_000, -2), (24_000, 0)] {
            let audio = GeminiTTSAudio(
                data: Data(repeating: 0x01, count: 8),
                mimeType: "audio/l16",
                sampleRate: rate,
                channels: channels
            )
            XCTAssertFalse(audio.isPlayableFormat, "\(rate) Hz / \(channels) ch must be refused")
            XCTAssertNil(audio.playableData)
        }
    }

    func testGeminiResponse_withUnusablePCMMetadata_isAnInvalidResponseNotACrash() {
        let body = Data("""
        {"steps":[{"content":[{"type":"audio","data":"AAAA","mime_type":"audio/l16",\
        "sample_rate":-48000,"channels":1}]}]}
        """.utf8)
        XCTAssertThrowsError(try GeminiTTSAPI.audio(from: body, requestedSampleRate: 24_000)) { error in
            XCTAssertEqual(error as? GeminiTTSAPIError, .invalidResponse)
        }
    }

    func testGeminiCost_chargesReportedInputTokensAndFallsBackToTheEstimate() {
        let model = GeminiTTSCatalog.defaultModel
        // 1,000 reported tokens at $1 per million.
        XCTAssertEqual(
            model.inputCost(characterCount: 10, reportedTokens: 1_000),
            Decimal(string: "0.001")
        )
        // No usage block: four characters per token, rounded up.
        XCTAssertEqual(
            model.inputCost(characterCount: 4_001, reportedTokens: nil),
            Decimal(1_001) * model.costPerInputToken
        )
        XCTAssertEqual(model.inputCost(characterCount: 0, reportedTokens: nil), 0)
    }

    func testGeminiUsage_isReadFromTheInteractionResponse() throws {
        let body = Data("""
        {"usage":{"input_tokens":42},"steps":[{"content":[{"type":"audio","data":"AAAA",\
        "mime_type":"audio/l16","sample_rate":24000,"channels":1}]}]}
        """.utf8)
        let audio = try GeminiTTSAPI.audio(from: body, requestedSampleRate: 24_000)
        XCTAssertEqual(audio.inputTokens, 42)
    }

    func testGeminiErrors_readTheInteractionsCodeAndTheLegacyEnvelope() {
        let auth = GeminiTTSAPI.error(
            from: Data(#"{"error":{"code":"authentication","message":"invalid key"}}"#.utf8),
            statusCode: 401
        )
        guard case .unauthorized = auth else { return XCTFail("expected unauthorized, got \(auth)") }

        let quota = GeminiTTSAPI.error(
            from: Data(#"{"error":{"code":"quota_exceeded","message":"daily quota"}}"#.utf8),
            statusCode: 429
        )
        guard case .rateLimited = quota else { return XCTFail("expected rate limiting, got \(quota)") }

        let blocked = GeminiTTSAPI.error(
            from: Data(#"{"error":{"code":"prohibited_content","message":"declined"}}"#.utf8),
            statusCode: 400
        )
        guard case .contentBlocked = blocked else {
            return XCTFail("expected a content block, got \(blocked)")
        }

        // The legacy generateContent envelope carries an integer code and a status.
        let legacy = GeminiTTSAPI.error(
            from: Data(#"{"error":{"code":429,"message":"out of quota","status":"RESOURCE_EXHAUSTED"}}"#.utf8),
            statusCode: 429
        )
        guard case .rateLimited = legacy else { return XCTFail("expected rate limiting, got \(legacy)") }
    }

    func testGeminiSynthesize_retriesOnceWhenNoAudioComesBack() async throws {
        let counter = TTSTransportCallCounter()
        TTSTransportMockURLProtocol.requestHandler = { request in
            let attempt = counter.next()
            let body = attempt == 0
                ? Data(#"{"steps":[{"content":[{"type":"text","text":"sorry"}]}]}"#.utf8)
                : TTSTransportStub.geminiAudioResponse()
            return (TTSTransportStub.response(for: request, statusCode: 200), body)
        }
        let api = GeminiTTSAPI(session: TTSTransportStub.session())

        let audio = try await api.synthesize(
            input: "Hello there",
            apiKey: "AIza-test",
            request: GeminiTTSRequest(voiceID: "google/Kore")
        )

        XCTAssertEqual(counter.count, 2)
        XCTAssertFalse(audio.data.isEmpty)
    }
}
