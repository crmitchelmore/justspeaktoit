import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// Runs the shared Deepgram synthesis path through an injected local
/// transport. No vendor credential or network is used; the key is a fixture.
class DeepgramSpeechStubTestCase: XCTestCase {
    var session: URLSession!
    let pcm = DeepgramSpeechFixture.pcm(frames: 4_800)

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        super.tearDown()
    }

    func synthesize(
        _ request: DeepgramSpeechRequest, with synthesizer: DeepgramSpeechSynthesizer? = nil
    ) async throws -> DeepgramSpeechAudio {
        let synthesizer = synthesizer ?? DeepgramSpeechSynthesizer(session: session)
        let utterance = try XCTUnwrap(try synthesizer.utterance(for: request))
        return try await synthesizer.synthesize(utterance, apiKey: "fixture-key")
    }

    func sentText(_ request: URLRequest) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request))
        let fields = try XCTUnwrap(object as? [String: String])
        XCTAssertEqual(Array(fields.keys), ["text"])
        return fields["text"]
    }

    func assertFailure(
        _ expected: DeepgramSpeechError, _ synthesizer: DeepgramSpeechSynthesizer, _ request: DeepgramSpeechRequest,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await synthesize(request, with: synthesizer)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, expected, "\(error)", file: file, line: line)
        }
    }

    func assertCancelled(
        _ task: Task<DeepgramSpeechAudio, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }
}

/// Request shape, canonical voices, pronunciation and limits.
final class DeepgramSpeechSynthesizerTests: DeepgramSpeechStubTestCase {
    func testAuraAndFluxVoices_SendTheCanonicalEndpointVoiceFormatAndTokenAuthorization() async throws {
        let streamed = DeepgramSpeechFixture.streamedWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), streamed) }
        for (voiceID, path) in [
            ("aura-2-thalia-en", "/v1/speak"), ("aura-angus-en", "/v1/speak"), ("flux-kit-en", "/v2/speak")
        ] {
            StubURLProtocol.resetRecordedRequests()
            let request = try DeepgramSpeechRequest(text: "Hello there.", modelID: nil, voiceID: "deepgram/\(voiceID)")
            XCTAssertEqual(request.voice.id, voiceID)
            let audio = try await synthesize(request)
            XCTAssertEqual(audio.wav, DeepgramSpeechFixture.canonicalWAV(pcm: pcm))

            let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
            XCTAssertEqual(sent.url?.scheme, "https")
            XCTAssertEqual(sent.url?.host, "api.deepgram.com")
            XCTAssertEqual(sent.url?.path, path)
            XCTAssertEqual(sent.httpMethod, "POST")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Token fixture-key")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let query = URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query, [
                URLQueryItem(name: "model", value: voiceID), URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "container", value: "wav"), URLQueryItem(name: "sample_rate", value: "24000")
            ])
            XCTAssertEqual(try sentText(sent), "Hello there.")
        }
    }

    private struct StoredSelection {
        let modelID: String?
        let voiceID: String?
        let expected: String
    }

    func testStoredIdentifiers_ResolveThroughTheCanonicalCatalogueMigrations() throws {
        let cases = [
            StoredSelection(modelID: "aura-2", voiceID: "asteria", expected: "aura-2-asteria-en"),
            StoredSelection(modelID: "aura", voiceID: "deepgram/aura-2-luna-en", expected: "aura-luna-en"),
            StoredSelection(modelID: " flux ", voiceID: "deepgram/flux-haley-en", expected: "flux-haley-en"),
            StoredSelection(modelID: "flux", voiceID: "asteria", expected: "flux-kit-en"),
            StoredSelection(modelID: nil, voiceID: "flux-kit-en", expected: "flux-kit-en"),
            StoredSelection(modelID: nil, voiceID: nil, expected: "aura-2-asteria-en")
        ]
        for stored in cases {
            let request = try DeepgramSpeechRequest(text: "Hi", modelID: stored.modelID, voiceID: stored.voiceID)
            XCTAssertEqual(request.voice.id, stored.expected)
            XCTAssertEqual(
                request.voice,
                DeepgramSpeechCatalog.resolvedSelection(modelID: stored.modelID, voiceID: stored.voiceID).voice
            )
        }
    }

    func testUnsupportedSpeedAndUncataloguedVoice_AreRefusedAtConstruction() throws {
        let voice = try XCTUnwrap(DeepgramSpeechCatalog.voices.first)
        for speed in [0.5, 1.05, 2, 0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try DeepgramSpeechRequest(text: "Hi", voice: voice, speed: speed)) {
                XCTAssertEqual($0 as? DeepgramSpeechError, .unsupportedSpeed, "\(speed)")
            }
        }
        XCTAssertNoThrow(try DeepgramSpeechRequest(text: "Hi", voice: voice, speed: 1))
        let invented = DeepgramSpeechCatalog.Voice(
            id: "aura-2-invented-en", name: "Invented", model: voice.model,
            gender: voice.gender, accent: voice.accent, style: voice.style
        )
        XCTAssertThrowsError(try DeepgramSpeechRequest(text: "Hi", voice: invented)) {
            XCTAssertEqual($0 as? DeepgramSpeechError, .unknownVoice)
        }
    }

    func testPronunciationAndUnicode_AreRenderedIntoTheRequestBody() async throws {
        let entries = PronunciationParityFixture.rules.map {
            PronunciationEntry(
                word: $0.word, pronunciation: $0.pronunciation, replacement: $0.replacement,
                isRegex: $0.isRegex, caseSensitive: $0.caseSensitive
            )
        }
        let streamed = DeepgramSpeechFixture.streamedWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), streamed) }
        let text = "\n  The API reached ZÜRICH and 東京 in 250ms 🙂; café stays.\t"
        let request = try DeepgramSpeechRequest(
            text: text, modelID: "aura-2", voiceID: "thalia", pronunciation: entries
        )
        _ = try await synthesize(request)
        let expected = "The A P I reached Tsoo-rick and Tokyo in 250 milliseconds 🙂; café stays."
        XCTAssertEqual(try sentText(try XCTUnwrap(StubURLProtocol.lastRequest)), expected)
        XCTAssertEqual(
            try DeepgramSpeechSynthesizer().utterance(for: request)?.characterCount, expected.unicodeScalars.count
        )
    }

    func testWhitespaceAndPronouncedAwayText_HaveNothingToSpeak() throws {
        let synthesizer = DeepgramSpeechSynthesizer(session: session)
        let erase = PronunciationEntry(word: "\\bum\\b", pronunciation: "", replacement: " ", isRegex: true)
        let cases: [(String, [PronunciationEntry])] = [("", []), ("  \n\t ", []), (" um  um ", [erase])]
        for (text, entries) in cases {
            let request = try DeepgramSpeechRequest(text: text, modelID: nil, voiceID: nil, pronunciation: entries)
            XCTAssertNil(try synthesizer.utterance(for: request), text)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testCharacterLimit_CountsRenderedScalarsAndNeverTruncates() throws {
        let synthesizer = DeepgramSpeechSynthesizer(session: session)
        func count(_ text: String, _ entries: [PronunciationEntry] = []) throws -> Int? {
            try synthesizer.utterance(for: DeepgramSpeechRequest(
                text: text, modelID: nil, voiceID: nil, pronunciation: entries
            ))?.characterCount
        }
        func assertTooLong(_ text: String, _ entries: [PronunciationEntry] = [], counting expected: Int) {
            XCTAssertThrowsError(try count(text, entries)) {
                XCTAssertEqual($0 as? DeepgramSpeechError, .textTooLong(characterCount: expected, limit: 2_000))
            }
        }
        XCTAssertEqual(try count(String(repeating: "a", count: 2_000)), 2_000)
        assertTooLong(String(repeating: "a", count: 2_001), counting: 2_001)
        // Pronunciation can push a text that fits over the limit.
        let api = PronunciationEntry(word: "API", pronunciation: "A P I", replacement: "A P I")
        let source = String(repeating: "b", count: 1_995) + " API"
        XCTAssertEqual(source.unicodeScalars.count, 1_999)
        assertTooLong(source, [api], counting: 2_001)
        // A family emoji is one character but five scalars.
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(try count(String(repeating: family, count: 400)), 2_000)
        assertTooLong(String(repeating: family, count: 401), counting: 2_005)
        // Oversized input is refused before pronunciation work.
        assertTooLong(String(repeating: "c", count: 20_001), counting: 20_001)
    }

    func testSourceWorkBound_MeasuresTheExactTextGivenToPronunciation() throws {
        // A single letter inside huge padding must not run every expression over
        // the padding: the bound applies to the untrimmed text the renderer sees.
        let renderer = PronunciationRenderer(retention: .activeDictionary)
        let synthesizer = DeepgramSpeechSynthesizer(session: session, renderer: renderer)
        let entries = [PronunciationEntry(word: "a", pronunciation: "ay", replacement: "ay")]
        let padding = String(repeating: " ", count: 20_000)
        for text in [padding + "a", "a" + padding, " " + padding + "a\n"] {
            let request = try DeepgramSpeechRequest(text: text, modelID: nil, voiceID: nil, pronunciation: entries)
            XCTAssertThrowsError(try synthesizer.utterance(for: request)) {
                XCTAssertEqual(
                    $0 as? DeepgramSpeechError,
                    .textTooLong(characterCount: text.unicodeScalars.count, limit: 2_000)
                )
            }
        }
        XCTAssertEqual(renderer.compilationCount, 0, "Pronunciation ran on oversized input")
        // Whitespace alone is still nothing to speak, whatever its size.
        let blank = try DeepgramSpeechRequest(
            text: String(repeating: " \n", count: 20_000), modelID: nil, voiceID: nil, pronunciation: entries
        )
        XCTAssertNil(try synthesizer.utterance(for: blank))
        // At the bound, pronunciation runs on exactly that text.
        let bounded = try DeepgramSpeechRequest(
            text: String(repeating: " ", count: 19_999) + "a", modelID: nil, voiceID: nil, pronunciation: entries
        )
        XCTAssertEqual(try synthesizer.utterance(for: bounded)?.text, "ay")
        XCTAssertEqual(renderer.compilationCount, 1)
    }

    func testRequestSnapshot_IgnoresLaterChangesToTheCallersDictionary() throws {
        var entries = [PronunciationEntry(word: "API", pronunciation: "A P I", replacement: "A P I")]
        let request = try DeepgramSpeechRequest(
            text: "API docs", modelID: "aura-2", voiceID: "luna", pronunciation: entries
        )
        entries[0].replacement = "changed"
        entries.append(PronunciationEntry(word: "docs", pronunciation: "x", replacement: "manuals"))
        XCTAssertEqual(request.pronunciation.map(\.replacement), ["A P I"])
        XCTAssertEqual(try DeepgramSpeechSynthesizer().utterance(for: request)?.text, "A P I docs")
        XCTAssertEqual(request.voice.id, "aura-2-luna-en")
    }
}

/// Status classification, audio validation, response bounds, the deadline and
/// cancellation, on both transport engines where they differ.
final class DeepgramSpeechTransportTests: DeepgramSpeechStubTestCase {
    func testErrorStatuses_AreClassifiedFromHeadersWithoutReadingTheBody() async throws {
        let request = try DeepgramSpeechRequest(text: "Secret words", modelID: nil, voiceID: nil)
        let echoed = Data(#"{"err_msg":"Secret words fixture-key"}"#.utf8)
        let cases: [(Int, DeepgramSpeechError)] = [
            (401, .unauthorized(statusCode: 401)), (403, .unauthorized(statusCode: 403)),
            (400, .httpStatus(400)), (429, .httpStatus(429)), (500, .httpStatus(500)), (302, .httpStatus(302))
        ]
        for (status, expected) in cases {
            let stopped = expectation(description: "HTTP \(status) transfer stops")
            StubURLProtocol.onStopLoading = { stopped.fulfill() }
            StubURLProtocol.handler = { sent in
                .respondWithoutFinishing(
                    DeepgramSpeechFixture.response(sent, status: status, headers: ["Content-Type": "application/json"]),
                    echoed
                )
            }
            do {
                _ = try await synthesize(request)
                XCTFail("HTTP \(status) was accepted")
            } catch {
                XCTAssertEqual(error as? DeepgramSpeechError, expected)
                XCTAssertFalse(error.localizedDescription.contains("Secret"), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("fixture-key"), error.localizedDescription)
            }
            await fulfillment(of: [stopped], timeout: 5)
        }
    }

    func testInvalidAudio_IsRejectedAfterTheExchange() async throws {
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        let bodies: [(Data, DeepgramSpeechError)] = [
            (Data(), .emptyAudio),
            (Data(#"{"ok":true}"#.utf8), .unsupportedAudioFormat),
            (DeepgramSpeechFixture.streamedWAV(pcm: Data(count: 480)), .silentAudio),
            (DeepgramSpeechFixture.canonicalWAV(pcm: pcm, rate: 16_000), .unsupportedAudioFormat)
        ]
        for (body, expected) in bodies {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), body) }
            do {
                _ = try await synthesize(request)
                XCTFail("Expected \(expected)")
            } catch { XCTAssertEqual(error as? DeepgramSpeechError, expected) }
        }
    }

    func testOversizedResponses_StopTheTransferOnBothEngines() async throws {
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        for engine in [OpenRouterBoundedResponseTransport.Engine.platformDefault, .delegate] {
            for declared in [true, false] {
                let stopped = expectation(description: "Over-limit transfer stops")
                StubURLProtocol.onStopLoading = { stopped.fulfill() }
                StubURLProtocol.handler = { sent in
                    .respondWithoutFinishing(
                        DeepgramSpeechFixture.response(sent, headers: declared ? ["Content-Length": "4096"] : [:]),
                        declared ? Data() : Data(repeating: 1, count: 2_048)
                    )
                }
                let synthesizer = DeepgramSpeechSynthesizer(session: session, responseLimit: 1_024, engine: engine)
                await assertFailure(.responseTooLarge, synthesizer, request)
                await fulfillment(of: [stopped], timeout: 5)
            }
        }
    }

    func testDeadline_StopsASynthesisThatNeverFinishes() async throws {
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        for engine in [OpenRouterBoundedResponseTransport.Engine.platformDefault, .delegate] {
            let stopped = expectation(description: "Hanging transfer stops")
            StubURLProtocol.onStopLoading = { stopped.fulfill() }
            StubURLProtocol.handler = { _ in .hang }
            let synthesizer = DeepgramSpeechSynthesizer(session: session, deadline: .milliseconds(200), engine: engine)
            await assertFailure(.timedOut, synthesizer, request)
            await fulfillment(of: [stopped], timeout: 5)
        }
    }

    func testCancellation_BeforeAndDuringTheExchangeStopsTheTransfer() async throws {
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        StubURLProtocol.handler = { _ in .hang }
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.synthesize(request)
        }
        await assertCancelled(early)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)

        for engine in [OpenRouterBoundedResponseTransport.Engine.platformDefault, .delegate] {
            StubURLProtocol.resetRecordedRequests()
            let started = expectation(description: "Transfer started")
            let stopped = expectation(description: "Transfer stopped")
            StubURLProtocol.onStartLoading = { started.fulfill() }
            StubURLProtocol.onStopLoading = { stopped.fulfill() }
            let synthesizer = DeepgramSpeechSynthesizer(session: session, deadline: .seconds(30), engine: engine)
            let task = Task { try await self.synthesize(request, with: synthesizer) }
            await fulfillment(of: [started], timeout: 5)
            task.cancel()
            await assertCancelled(task)
            await fulfillment(of: [stopped], timeout: 5)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        }
    }
}

/// `DeepgramTTSAPI` now shares its request builder and status classification
/// with the portable path. Its public behaviour for Apple callers is unchanged.
final class DeepgramTTSAPIContractTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSynthesize_KeepsItsRequestShapeAndErrorMessages() async throws {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let api = DeepgramTTSAPI(session: session)
        let passthrough = [
            URLQueryItem(name: "model", value: "flux-kit-en"), URLQueryItem(name: "encoding", value: "mp3")
        ]
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), Data([1, 2, 3])) }
        let data = try await api.synthesize(text: "Hi", apiKey: "raw key", queryItems: passthrough)
        XCTAssertEqual(data, Data([1, 2, 3]))
        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.path, "/v2/speak")
        let query = URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, passthrough)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Token raw key")

        let aura = [URLQueryItem(name: "model", value: "aura")]
        for (status, expected) in [
            (401, DeepgramTTSAPIError.unauthorized(statusCode: 401, message: "denied")),
            (403, .unauthorized(statusCode: 403, message: "denied")),
            (500, .httpError(statusCode: 500, message: "denied")),
            (204, nil)
        ] as [(Int, DeepgramTTSAPIError?)] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("denied".utf8))
            }
            do {
                _ = try await api.synthesize(text: "Hi", apiKey: "key", queryItems: aura)
                XCTAssertNil(expected, "HTTP \(status) was accepted")
            } catch { XCTAssertEqual(error as? DeepgramTTSAPIError, expected) }
        }
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/speak")
    }
}
