import Foundation
import XCTest

@testable import SpeakCore

/// Protocol tests for the shared Rev.ai streaming client, driven with the
/// frames the documented example session sends.
final class RevAILiveClientTests: XCTestCase {

    // MARK: - Request

    func testWebSocketURL_carriesTheRawPCMContentTypeAndAccessToken() throws {
        let url = try XCTUnwrap(RevAILiveClient.webSocketURL(
            accessToken: "token", sampleRate: 16_000, language: "en_GB"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.rev.ai")
        XCTAssertEqual(components.path, "/speechtotext/v1/stream")
        // Rev.ai authenticates the socket with a query parameter; Bearer is
        // documented only for its two HTTP endpoints.
        XCTAssertEqual(items["access_token"], "token")
        XCTAssertEqual(
            items["content_type"],
            "audio/x-raw;layout=interleaved;rate=16000;format=S16LE;channels=1"
        )
        XCTAssertEqual(items["transcriber"], "machine_v2")
        XCTAssertEqual(items["language"], "en")
    }

    func testWebSocketURL_automaticLanguageResolvesTheSystemLocale() throws {
        let url = try XCTUnwrap(RevAILiveClient.webSocketURL(
            accessToken: "token", sampleRate: 16_000, language: nil, systemLocaleIdentifier: "fr_FR"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "language", value: "fr")) == true)
    }

    func testWebSocketURL_omitsAnUnsupportedLanguageRatherThanSendingABadOne() throws {
        // Rev.ai documents nine streaming languages and rejects the parameter
        // for anything else; omitting it means English, which is the
        // documented default.
        let url = try XCTUnwrap(RevAILiveClient.webSocketURL(
            accessToken: "token", sampleRate: 16_000, language: nil, systemLocaleIdentifier: "cs_CZ"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertFalse(components.queryItems?.contains { $0.name == "language" } == true)
    }

    func testMandarinIsSentAsRevAIsOwnCode() {
        XCTAssertEqual(
            RevAIStreaming.languageCode(for: nil, systemLocaleIdentifier: "zh_CN"), "cmn"
        )
    }

    func testEndOfStreamTokenIsTheExactCaseSensitiveLiteral() {
        // Rev.ai closes the socket with 1007 for `eos` or `Eos`, and a real
        // close frame loses the final hypothesis entirely.
        XCTAssertEqual(RevAILiveClient.endOfStreamToken, "EOS")
    }

    // MARK: - Transcript reconstruction

    func testFinalConcatenatesPunctElementsWithoutInsertingSpaces() {
        // A final's `punct` elements carry the spacing as well as the
        // punctuation, so a separator would produce "One  two .".
        let object = Self.object(Self.finalFrame)

        XCTAssertEqual(RevAIStreamingEvent.finalText(from: object), "One two.")
    }

    func testPartialJoinsTextElementsWithSingleSpaces() {
        // Partials carry no punct elements at all, so the client must space them.
        let object = Self.object(Self.partial(["one", "tooth"]))

        XCTAssertEqual(RevAIStreamingEvent.partialText(from: object), "one tooth")
    }

    func testFinishAndWait_returnsTheWholeSessionNotTheTrailingSegment() async {
        let client = Self.armedClient()

        client.ingest(Self.finalFrame)
        client.ingest(Self.partial(["five", "sticks"]))
        client.ingest(Self.final("Five six."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "One two. Five six.")
    }

    func testPartialsRestateTheCurrentSegmentAndAreNeverFolded() async {
        var events: [(String, Bool)] = []
        let client = RevAILiveClient(accessToken: "t")
        client.beginSession(onTranscript: { events.append(($0, $1)) }, onError: { _ in })

        client.ingest(Self.partial(["one"]))
        client.ingest(Self.partial(["one", "tooth"]))
        client.ingest(Self.finalFrame)

        XCTAssertEqual(events.map(\.0), ["one", "one tooth", "One two."])
        XCTAssertEqual(events.map(\.1), [false, false, true])
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "One two.")
    }

    func testRepeatedIdenticalFinalsAreBothKept() async {
        // Issue #700: each final covers a new [ts, end_ts] window, so identical
        // text is two utterances rather than a resend.
        let client = Self.armedClient()

        client.ingest(Self.final("Yes."))
        client.ingest(Self.final("Yes."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Yes. Yes.")
    }

    func testEmptyAudioSessionFinishesWithNoTranscript() async {
        let client = Self.armedClient()

        client.ingest(Self.partial(["um"]))
        client.ingest(#"{"type":"final","ts":0,"end_ts":1,"elements":[]}"#)

        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    func testUnknownFramesNeverEndTheSession() async {
        let client = Self.armedClient()

        client.ingest(#"{"type":"connected","id":"s1d24ax2fd21"}"#)
        client.ingest(#"{"type":"something_new_upstream"}"#)
        client.ingest(Self.final("Still here."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Still here.")
    }

    // MARK: - Failures

    func testAuthenticationFailureIsTheDocumented4001() {
        guard case .invalidAPIKey(let provider)? =
            RevAIStreamingError.forCloseCode(4001) as? StreamingClientError else {
            return XCTFail("4001 must map to a rejected key")
        }
        XCTAssertEqual(provider, "Rev.ai")
    }

    func testQuotaFailureIsTheDocumented4003AndIsNotABadKey() {
        // A stored access token is not credit: an exhausted balance is an
        // account state to top up, not a credential to re-enter.
        XCTAssertEqual(
            RevAIStreamingError.forCloseCode(4003) as? RevAIStreamingError, .insufficientCredits
        )
    }

    func testTheRemainingDocumentedCloseCodesAreClassified() {
        XCTAssertEqual(RevAIStreamingError.forCloseCode(4002) as? RevAIStreamingError, .badRequest)
        XCTAssertEqual(
            RevAIStreamingError.forCloseCode(4010) as? RevAIStreamingError,
            .temporarilyUnavailable(closeCode: 4010)
        )
        XCTAssertEqual(
            RevAIStreamingError.forCloseCode(4013) as? RevAIStreamingError,
            .temporarilyUnavailable(closeCode: 4013)
        )
        XCTAssertEqual(
            RevAIStreamingError.forCloseCode(4029) as? RevAIStreamingError, .tooManyConnections
        )
    }

    func testANormalCloseIsNotAFailure() {
        // The socket closing after EOS is the documented end of a session.
        XCTAssertNil(RevAIStreamingError.forCloseCode(1000))
        XCTAssertNil(RevAIStreamingError.forCloseCode(0))
    }

    func testMissingAccessTokenFailsBeforeAnySocketIsOpened() {
        var failure: Error?
        RevAILiveClient(accessToken: "  ").start(onTranscript: { _, _ in }, onError: { failure = $0 })

        guard case .missingAPIKey(let provider)? = failure as? StreamingClientError else {
            return XCTFail("expected a missing-key error, got \(String(describing: failure))")
        }
        XCTAssertEqual(provider, "Rev.ai")
    }

    func testFinishAfterASocketDropStillReturnsWhatWasTranscribed() async {
        let client = Self.armedClient()
        client.ingest(Self.final("Partial session."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Partial session.")
    }

    func testCancellationClearsHeldAudioAndResolvesAWaiter() async {
        let client = RevAILiveClient(accessToken: "t")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 0, count: 8_000))
        XCTAssertFalse(client.preroll.isEmpty)

        client.stop()

        XCTAssertTrue(client.preroll.isEmpty)
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    // MARK: - Audio handling

    func testAudioBeforeConnectedIsHeldNotDropped() {
        // Issue #641: Rev.ai rejects audio before its `connected` frame, and
        // bursting the backlog afterwards is explicitly supported.
        let client = RevAILiveClient(accessToken: "t")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        XCTAssertFalse(client.isSessionReady)
        client.sendAudio(Data(repeating: 1, count: 8_000))
        client.sendAudio(Data(repeating: 2, count: 8_000))

        XCTAssertEqual(client.preroll.snapshot.chunkCount, 2)
        XCTAssertEqual(client.preroll.snapshot.droppedChunkCount, 0)
    }

    func testEmptyAudioChunksAreNotBuffered() {
        let client = RevAILiveClient(accessToken: "t")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        client.sendAudio(Data())

        XCTAssertTrue(client.preroll.isEmpty)
    }

    // MARK: - Fixtures

    private static func armedClient() -> RevAILiveClient {
        let client = RevAILiveClient(accessToken: "t")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        return client
    }

    private static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    /// The documented final: `punct` elements carry the space and the stop.
    private static let finalFrame = """
    {"type":"final","ts":1.01,"end_ts":3.2,"elements":[\
    {"type":"text","value":"One","ts":1.04,"end_ts":1.55,"confidence":1.0},\
    {"type":"punct","value":" "},\
    {"type":"text","value":"two","ts":1.84,"end_ts":2.15,"confidence":1.0},\
    {"type":"punct","value":"."}]}
    """

    private static func final(_ text: String) -> String {
        #"{"type":"final","ts":0,"end_ts":1,"elements":[{"type":"text","value":"\#(text)"}]}"#
    }

    private static func partial(_ words: [String]) -> String {
        let elements = words.map { #"{"type":"text","value":"\#($0)"}"# }.joined(separator: ",")
        return #"{"type":"partial","ts":0,"end_ts":1,"elements":[\#(elements)]}"#
    }
}
