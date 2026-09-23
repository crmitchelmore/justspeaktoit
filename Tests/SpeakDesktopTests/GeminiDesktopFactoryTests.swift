import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// Gemini 3.5 Transcribe Live on desktop hosts: the canonical route is
/// projected once with its canonical credential and capture framing, and the
/// shared client the factory builds carries the selection as one of the Live
/// model's documented codes, over the host's own transport.
final class GeminiDesktopFactoryTests: XCTestCase {
    private let liveID = GeminiTranscribeModels.liveCatalogID

    func testCanonicalRouteIsProjectedWithItsCredentialCapabilityAndFraming() throws {
        XCTAssertEqual(DesktopLiveTranscription.liveModels.filter { $0.id == liveID }.count, 1)
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: " \(liveID)\n"))
        XCTAssertEqual(route.provider, .google)
        XCTAssertEqual(route.apiModelName, GeminiTranscribeModels.liveAPIName)
        XCTAssertEqual(route.sampleRate, 16_000)
        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: liveID))
        XCTAssertEqual(provider.apiKeyIdentifier, "google.apiKey")
        XCTAssertEqual(provider.displayName, "Google Gemini")
        XCTAssertTrue(DesktopLiveTranscription.languageHintModelIDs.contains(liveID))
        let milliseconds = DesktopLiveTranscription.captureFrameMilliseconds(forID: liveID)
        XCTAssertEqual(route.sampleRate * milliseconds / 1_000 * 2, 3_200, "100 ms frames, as the Live API asks")

        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: liveID, apiKey: "synthetic", language: "fr_FR",
            makeConnection: { _ in fatalError("Constructing a client must not open a connection") }
        ) as? GeminiLiveClient)
        XCTAssertEqual(client.finalisationBudget, GeminiLiveClient.finishBudget)
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        XCTAssertTrue(client.finishFlushesBufferedAudio)
        XCTAssertEqual(client.customVocabulary, [], "Desktop hosts keep no keyword list")
    }

    func testFactoryClientSendsTheDocumentedLanguageCodeInItsSetup() throws {
        let cases: [(String?, [String])] = [
            ("en_GB", ["en-GB"]), ("zh_CN", ["cmn-Hans-CN"]), ("es_MX", ["es-419"]), ("en_AU", []),
            ("ar_SA", []), (TranscriptionLanguageCatalog.automaticIdentifier, []), (nil, [])
        ]
        for (language, expected) in cases {
            let socket = try openedSocket(language: language)
            let setup = try XCTUnwrap(socket.texts.first)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(setup.utf8)) as? [String: Any])
            let transcription = try XCTUnwrap(
                (object["setup"] as? [String: Any])?["inputAudioTranscription"] as? [String: Any]
            )
            XCTAssertEqual(transcription["languageCodes"] as? [String], expected, language ?? "nil")
        }
    }

    func testFactoryClientOpensTheDocumentedEndpointWithTheSavedKey() throws {
        let factory = GeminiSocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: liveID, apiKey: "  synthetic-key ", makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
        defer { client.cancel() }
        let url = try XCTUnwrap(factory.requests.first?.url)
        XCTAssertEqual(url, GeminiLiveClient.webSocketURL(apiKey: "synthetic-key"))
        XCTAssertNil(factory.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    private func openedSocket(language: String?) throws -> GeminiTestSocket {
        let factory = GeminiSocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: liveID, apiKey: "synthetic", language: language, makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
        defer { client.cancel() }
        let socket = try XCTUnwrap(factory.sockets.first)
        socket.open()
        return socket
    }
}
