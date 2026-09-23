import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The Rev.ai streaming contract the shared client builds on, with the frames
/// of the documented example session: the request, language mapping, `EOS`,
/// transcript reconstruction and close-code classification.
final class RevAILiveProtocolTests: XCTestCase {
    // MARK: Request

    func testStartRequestsTheDocumentedStreamWithTheTrimmedTokenOnlyInTheQuery() throws {
        let fixture = RevAILiveFixture(token: " synthetic-token\n", language: "en_GB")
        fixture.start()
        defer { fixture.client.cancel() }
        let request = try XCTUnwrap(fixture.factory.requests.first)
        let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.rev.ai")
        XCTAssertEqual(components.path, "/speechtotext/v1/stream")
        let items = components.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["access_token", "content_type", "transcriber", "language"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }), [
            "access_token": "synthetic-token",
            "content_type": "audio/x-raw;layout=interleaved;rate=16000;format=S16LE;channels=1",
            "transcriber": "machine_v2",
            "language": "en"
        ])
        // Rev.ai authenticates the socket with the query parameter; Bearer is
        // documented only for its HTTP endpoints.
        XCTAssertEqual(request.allHTTPHeaderFields ?? [:], [:])
        XCTAssertEqual(fixture.socket.resumes, 1)
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testLanguageSelectionsResolveToRevAIsOwnCodesOrAreOmitted() throws {
        let system = RevAIStreaming.languageCode(for: nil)
        let cases: [(selection: String?, code: String?)] = [
            ("fr_FR", "fr"), ("pt-BR", "pt"), ("zh_CN", "cmn"), ("cs_CZ", nil), ("ru_RU", nil), (nil, system),
            (TranscriptionLanguageCatalog.automaticIdentifier, system), ("Automatic", system), (" ", system)
        ]
        for (selection, code) in cases {
            let fixture = RevAILiveFixture(language: selection)
            fixture.start()
            let url = try XCTUnwrap(fixture.factory.requests.first?.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "language" }?.value, code, String(describing: selection))
            XCTAssertEqual(query.filter { $0.name == "language" }.count, code == nil ? 0 : 1)
            fixture.client.cancel()
        }
    }

    func testAutomaticResolvesTheSystemLanguageBecauseAMissingCodeMeansEnglish() throws {
        let french = try XCTUnwrap(RevAILiveClient.webSocketURL(
            accessToken: "token", sampleRate: 16_000, language: nil, systemLocaleIdentifier: "fr_FR"
        ))
        XCTAssertTrue(URLComponents(url: french, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(URLQueryItem(name: "language", value: "fr")) == true)
        // Rev.ai documents nine streaming languages; anything else is omitted
        // rather than sent, which the service reads as English.
        let czech = try XCTUnwrap(RevAILiveClient.webSocketURL(
            accessToken: "token", sampleRate: 16_000, language: nil, systemLocaleIdentifier: "cs_CZ"
        ))
        XCTAssertFalse(URLComponents(url: czech, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "language" } == true)
        XCTAssertEqual(RevAIStreaming.languageCode(for: nil, systemLocaleIdentifier: "zh_CN"), "cmn")
    }

    func testEndOfStreamIsTheExactCaseSensitiveLiteral() {
        // Rev.ai closes the socket with 1007 for `eos` or `Eos`, and a real
        // close frame loses the final hypothesis entirely.
        XCTAssertEqual(RevAILiveClient.endOfStreamToken, "EOS")
    }

    // MARK: Frames

    func testFinalConcatenatesPunctElementsAndPartialJoinsWordsWithSpaces() {
        XCTAssertEqual(
            RevAIStreamingEvent(message: .text(CartesiaTestSocket.revAIDocumentedFinal)), .final("One two.")
        )
        let partial = CartesiaTestSocket.revAIHypothesis("partial", [
            ["type": "text", "value": "one"], ["type": "text", "value": "tooth"]
        ])
        XCTAssertEqual(RevAIStreamingEvent(message: .text(partial)), .partial("one tooth"))
        XCTAssertEqual(
            RevAIStreamingEvent(message: .binary(Data(CartesiaTestSocket.revAIDocumentedFinal.utf8))),
            .final("One two."), "JSON in a binary frame is read the same way"
        )
    }

    func testHypothesesWithoutWordsDecodeToEmptyTextSoTheyStillEndOrWithdrawASegment() {
        XCTAssertEqual(
            RevAIStreamingEvent(message: .text(CartesiaTestSocket.revAIHypothesis("final", []))), .final("")
        )
        let blank = CartesiaTestSocket.revAIHypothesis("partial", [["type": "text", "value": " "]])
        XCTAssertEqual(RevAIStreamingEvent(message: .text(blank)), .partial(""))
        XCTAssertEqual(RevAIStreamingEvent(message: .text(#"{"type":"final"}"#)), .final(""))
    }

    func testConnectedIsRecognisedAndEverythingElseIsIgnored() {
        XCTAssertEqual(RevAIStreamingEvent(message: .text(#"{"type":"connected","id":"s1d24ax2fd21"}"#)), .connected)
        for frame in [#"{"type":"something_new_upstream"}"#, #"{"elements":[]}"#, "not json", "[1,2]"] {
            XCTAssertNil(RevAIStreamingEvent(message: .text(frame)), frame)
        }
        XCTAssertNil(RevAIStreamingEvent(message: .binary(Data([0, 1, 2]))))
    }

    // MARK: Close codes

    func testDocumentedCloseCodesNameTheirCause() {
        let rejected = RevAIStreamingError.error(closeCode: 4_001) as? StreamingClientError
        guard case .invalidAPIKey(let provider)? = rejected else {
            return XCTFail("4001 must point the user at the access token")
        }
        XCTAssertEqual(provider, "Rev.ai")
        // A stored access token is not credit: an exhausted balance is an
        // account state to top up, not a credential to re-enter.
        XCTAssertEqual(RevAIStreamingError.error(closeCode: 4_003) as? RevAIStreamingError, .insufficientCredits)
        XCTAssertEqual(RevAIStreamingError.error(closeCode: 4_002) as? RevAIStreamingError, .badRequest)
        for code in [4_010, 4_013] {
            let unavailable = RevAIStreamingError.error(closeCode: code) as? RevAIStreamingError
            XCTAssertEqual(unavailable, .temporarilyUnavailable(closeCode: code))
        }
        XCTAssertEqual(RevAIStreamingError.error(closeCode: 4_029) as? RevAIStreamingError, .tooManyConnections)
    }

    func testEveryOtherCloseStatusIsAnUnexpectedClosureNeverASuccess() {
        for code in [1_001, 1_005, 1_006, 1_007, 1_011, 4_000] {
            XCTAssertEqual(
                RevAIStreamingError.error(closeCode: code) as? RevAIStreamingError, .closed(closeCode: code), "\(code)"
            )
        }
        let client = RevAILiveClient(accessToken: "synthetic", makeConnection: { _ in
            fatalError("Classifying a closure must not open a connection")
        })
        XCTAssertEqual(
            client.interruption(by: CartesiaTestPeerClose(webSocketCloseCode: 1_000)) as? RevAILiveError,
            .unexpectedCompletion, "A normal closure that did not answer EOS ended the stream early"
        )
        let dropped = URLError(.networkConnectionLost)
        XCTAssertEqual((client.interruption(by: dropped) as? URLError)?.code, .networkConnectionLost)
    }

    // MARK: Client contract

    func testLegacyInitializerKeepsItsSignatureAndDeclaresTheWholeFinishBudget() {
        let legacy: (String, String?, Int, URLSession) -> RevAILiveClient =
            RevAILiveClient.init(accessToken:language:sampleRate:session:)
        let client = legacy("synthetic", nil, 16_000, .shared)
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        XCTAssertTrue(client.finishFlushesBufferedAudio)
        XCTAssertEqual(client.finalisationBudget, RevAIStreaming.finishBudget)
    }
}
