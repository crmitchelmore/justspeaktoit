import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
import SpeakDesktop

/// Unknown-frame, empty-session and legacy-helper coverage through the real
/// transport, plus the native Desktop factory exposing the canonical
/// Speechmatics route, metadata and injected-language request.
final class SpeechmaticsDesktopFactoryTests: XCTestCase {
    private let liveID = "speechmatics/enhanced-streaming"

    // MARK: - Frames and sessions

    func testUnknownInfoAndWarningFramesNeverEndTheSession() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(#"{"message":"Info","type":"recognition_quality","reason":"quality"}"#)
        socket.emit(#"{"message":"Warning","type":"duration_limit","reason":"limit"}"#)
        socket.emit(#"{"message":"SomethingNewUpstream"}"#)
        socket.addFinal("Still here.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.endOfTranscript()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Still here.")
    }

    func testPartialOnlyAndEmptySessionsFinishEmpty() async {
        let partial = SpeechmaticsLiveFixture()
        partial.start(); partial.becomeReady()
        partial.socket.addPartial("um")
        let firstFinish = Task { await partial.client.finishAndWait() }
        await partial.settle { partial.socket.messageNames.last == "EndOfStream" }
        partial.socket.completeSend()
        partial.socket.endOfTranscript()
        let partialResult = await firstFinish.value
        XCTAssertNil(partialResult)

        let empty = SpeechmaticsLiveFixture()
        empty.start(); empty.becomeReady()
        let secondFinish = Task { await empty.client.finishAndWait() }
        await empty.settle { empty.socket.messageNames.last == "EndOfStream" }
        empty.socket.completeSend()
        empty.socket.endOfTranscript()
        let emptyResult = await secondFinish.value
        XCTAssertNil(emptyResult)
    }

    func testLegacyBeginSessionIngestAndAwaitFinalTranscriptStillWork() async {
        let client = SpeechmaticsLiveClient(apiKey: "k", makeConnection: { _ in SpeechmaticsAutoSocket() })
        let events = AssemblyAITestEvents()
        client.beginSession(onTranscript: { [events] in events.transcript($0, final: $1) }, onError: { _ in })
        client.ingest(#"{"message":"AddPartialTranscript","metadata":{"transcript":"hel"},"results":[]}"#)
        client.ingest(#"{"message":"AddTranscript","metadata":{"transcript":"Hello."},"results":[]}"#)
        let transcript = await client.awaitFinalTranscript(budget: 30) {
            client.ingest(#"{"message":"EndOfTranscript"}"#)
        }
        XCTAssertEqual(transcript, "Hello.")
        XCTAssertEqual(events.texts, ["hel", "Hello."])
        XCTAssertEqual(events.finals, [false, true])
    }

    // MARK: - Native desktop factory

    func testDesktopFactoryExposesTheCanonicalSpeechmaticsRouteAndMetadata() throws {
        XCTAssertTrue(DesktopLiveTranscription.liveModels.contains { $0.id == liveID })
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: liveID))
        XCTAssertEqual(route, LiveTranscriptionRouting.route(for: liveID))
        XCTAssertEqual(route.provider, .speechmatics)
        XCTAssertEqual(route.apiModelName, "enhanced")
        XCTAssertEqual(route.sampleRate, 16_000)

        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: liveID))
        XCTAssertEqual(provider.id, "speechmatics")
        XCTAssertEqual(provider.displayName, "Speechmatics")
        XCTAssertEqual(provider.apiKeyIdentifier, "speechmatics.apiKey")

        let client = DesktopLiveTranscription.makeClient(model: liveID, apiKey: "", makeConnection: { _ in
            fatalError("Constructing a client must not open a connection")
        })
        XCTAssertTrue(client is SpeechmaticsLiveClient)
    }

    func testDesktopFactoryRejectsBatchAndUnknownSpeechmaticsRoutes() {
        XCTAssertNil(DesktopLiveTranscription.route(forID: "speechmatics/enhanced"),
                     "The batch identifier is not a live desktop route")
        XCTAssertNil(DesktopLiveTranscription.route(forID: "speechmatics/unknown-streaming"))
        XCTAssertFalse(DesktopLiveTranscription.liveModels.contains { $0.id == "speechmatics/unknown-streaming" })
    }

    func testDesktopFactoryForwardsSelectedLanguageToTheStartRecognitionRequest() throws {
        let factory = AssemblyAISocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: liveID, apiKey: "k", language: "fr_FR", makeConnection: { factory.make($0) }
        ) as? SpeechmaticsLiveClient)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        factory.sockets[0].open()
        let config = try XCTUnwrap(factory.sockets[0].objects.first?["transcription_config"] as? [String: Any])
        XCTAssertEqual(config["language"] as? String, "fr")
        client.cancel()
    }

    func testDesktopFactoryGivesOpenAITheBareLanguageCodeAndDeepgramTheLocale() throws {
        let openAIFactory = AssemblyAISocketFactory()
        let openAI = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID, apiKey: "k", language: "fr_FR",
            makeConnection: { openAIFactory.make($0) }
        ) as? OpenAIRealtimeLiveClient)
        openAI.start(onTranscript: { _, _ in }, onError: { _ in })
        openAIFactory.sockets[0].open()
        let session = try XCTUnwrap(openAIFactory.sockets[0].sessionUpdate?["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["languages"] as? [String], ["fr"], "OpenAI sends the supplied string verbatim")
        openAI.cancel()

        let deepgramFactory = AssemblyAISocketFactory()
        let deepgram = DesktopLiveTranscription.makeClient(
            model: "deepgram/nova-3-streaming", apiKey: "k", language: "fr_FR",
            makeConnection: { deepgramFactory.make($0) }
        )
        XCTAssertTrue(deepgram is DeepgramLiveClient)
        deepgram?.start(onTranscript: { _, _ in }, onError: { _ in })
        let url = try XCTUnwrap(deepgramFactory.requests[0].url)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "language" }?.value, "fr", "Deepgram normalises the locale itself")
        deepgram?.cancel()
    }

    func testDesktopFactoryDefaultLanguageKeepsTheSystemLocaleFallback() throws {
        let factory = AssemblyAISocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: liveID, apiKey: "k", makeConnection: { factory.make($0) }
        ) as? SpeechmaticsLiveClient)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        factory.sockets[0].open()
        let config = try XCTUnwrap(factory.sockets[0].objects.first?["transcription_config"] as? [String: Any])
        XCTAssertEqual(config["language"] as? String, SpeechmaticsRealtime.languageCode(for: nil),
                       "A nil selection keeps the existing system-locale fallback")
        client.cancel()
    }
}
