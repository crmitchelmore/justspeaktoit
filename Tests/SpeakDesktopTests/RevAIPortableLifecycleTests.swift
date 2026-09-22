import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The shared Rev.ai client's stream lifecycle over the injected transport:
/// readiness, ordering, the drain before `EOS`, and completion at the normal
/// close. Failures and isolation live in the neighbouring files.
final class RevAIPortableLifecycleTests: XCTestCase {
    func testStartRequestsTheDocumentedStream_withTheTokenInTheQueryOnly() throws {
        let fixture = RevAILiveFixture(language: "en_GB")
        fixture.start()
        defer { fixture.client.cancel() }
        let request = try XCTUnwrap(fixture.factory.requests.first)
        let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.rev.ai")
        XCTAssertEqual(components.path, "/speechtotext/v1/stream")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, [
            "access_token": "synthetic-token",
            "content_type": "audio/x-raw;layout=interleaved;rate=16000;format=S16LE;channels=1",
            "transcriber": "machine_v2",
            "language": "en"
        ])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Bearer is documented only for HTTP")
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testLanguageSelectionsResolveToRevAIsOwnCodes_orAreOmitted() throws {
        let cases: [(String?, String?)] = [
            ("fr_FR", "fr"), ("zh_CN", "cmn"), ("cs_CZ", nil),
            (nil, RevAIStreaming.languageCode(for: nil)),
            (TranscriptionLanguageCatalog.automaticIdentifier, RevAIStreaming.languageCode(for: nil))
        ]
        for (selection, expected) in cases {
            let fixture = RevAILiveFixture(language: selection)
            fixture.start()
            let url = try XCTUnwrap(fixture.factory.requests.first?.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "language" }?.value, expected, String(describing: selection))
            fixture.client.cancel()
        }
    }

    func testAudioWaitsForTheHandshakeAndConnected_thenLeavesInCaptureOrderOneAtATime() {
        let fixture = RevAILiveFixture()
        fixture.start()
        defer { fixture.client.cancel() }
        let frames = (0..<3).map { RevAILiveFixture.frame($0) }
        frames.forEach(fixture.client.sendAudio)
        XCTAssertEqual(fixture.client.preroll.snapshot.chunkCount, 3)
        fixture.socket.open()
        XCTAssertTrue(fixture.socket.binary.isEmpty, "The handshake alone is not Rev.ai readiness")
        XCTAssertFalse(fixture.client.isSessionReady)
        fixture.socket.connected()
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertEqual(fixture.socket.binary, [frames[0]], "One frame is in flight")
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, Array(frames[0...1]))
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0)
        XCTAssertTrue(fixture.client.preroll.isEmpty)
        XCTAssertTrue(fixture.socket.controls.isEmpty, "Nothing but PCM leaves while streaming")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testConnectedReportedBeforeTheHandshake_stillWaitsForTheHandshake() {
        let fixture = RevAILiveFixture()
        fixture.start()
        defer { fixture.client.cancel() }
        fixture.client.sendAudio(RevAILiveFixture.frame(0))
        fixture.socket.connected()
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        XCTAssertFalse(fixture.client.isSessionReady)
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.binary, [RevAILiveFixture.frame(0)])
    }

    func testSynchronousSendCompletions_neverNestAndKeepCaptureOrder() {
        let fixture = RevAILiveFixture()
        fixture.start()
        defer { fixture.client.cancel() }
        fixture.becomeReady()
        let depth = NestingProbe()
        let socket = fixture.socket
        socket.onSend = { _ in
            depth.enter()
            socket.completeSend()
            depth.leave()
        }
        let frames = (0..<200).map { RevAILiveFixture.frame($0, count: 320) }
        fixture.client.sendAudio(frames[0])
        // Queue the rest behind a held send, then release them all at once.
        socket.onSend = nil
        frames.dropFirst().forEach(fixture.client.sendAudio)
        socket.onSend = { _ in
            depth.enter()
            socket.completeSend()
            depth.leave()
        }
        socket.completeSend()
        XCTAssertEqual(socket.binary, frames)
        XCTAssertEqual(depth.maximum, 1, "A synchronous completion must not start a nested send")
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0)
    }

    func testFinishDrainsAudioThenSendsTheLiteralEOS_andCompletesAtTheNormalClose() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        let frames = (0..<3).map { RevAILiveFixture.frame($0) }
        frames.forEach(fixture.client.sendAudio)
        fixture.socket.emit(RevAILiveFixture.documentedFinal)
        fixture.socket.partialHypothesis(["five", "sticks"])
        let endOfStream = expectation(description: "EOS handed to the transport")
        fixture.socket.fulfillOnEndOfStream(endOfStream)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForFinishWaiters()
        XCTAssertTrue(fixture.socket.controls.isEmpty, "EOS waits behind every admitted frame")
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        fixture.socket.completeSend()
        await fulfillment(of: [endOfStream], timeout: 2)
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertEqual(fixture.socket.controls, ["EOS"])
        fixture.client.sendAudio(RevAILiveFixture.frame(9))
        XCTAssertEqual(fixture.socket.binary, frames, "Audio offered after the finish began is not sent")
        fixture.socket.completeSend()
        fixture.socket.finalHypothesis("Five six.")
        fixture.socket.peerClose(1_000)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "One two. Five six.")
        XCTAssertTrue(fixture.events.errors.isEmpty, "\(fixture.events.errors)")
        XCTAssertEqual(fixture.events.texts, ["One two.", "five sticks"], "The trailing final is returned, not delivered")
        XCTAssertEqual(fixture.events.finals, [true, false])
        fixture.clock.drain().forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty, "Deadlines of a completed run are inert")
    }

    func testNormalCloseArrivingBeforeEOSWriteCompletes_stillCompletesAfterHandOff() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.stream([RevAILiveFixture.frame(0)])
        let endOfStream = expectation(description: "EOS handed to the transport")
        fixture.socket.fulfillOnEndOfStream(endOfStream)
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.finalHypothesis("Done.")
        fixture.socket.peerClose(1_000)
        fixture.socket.completeSend(RevAITestPeerClose(webSocketCloseCode: 1_000))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Done.")
        XCTAssertTrue(fixture.events.errors.isEmpty, "\(fixture.events.errors)")
    }

    func testSilenceCompletesWithNoTranscriptAndNoError() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.stream((0..<5).map { _ in Data(count: 3_200) })
        let endOfStream = expectation(description: "EOS handed to the transport")
        fixture.socket.fulfillOnEndOfStream(endOfStream)
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.peerClose(1_000)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.events.texts.isEmpty)
    }

    func testFinishWithoutAudio_closesAtOnceWithoutOpeningAStreamToEnd() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.socket.endOfStreamFrames.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishDuringTheHandshake_keepsTheCaptureAndSendsItOnceConnected() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        let frames = (0..<2).map { RevAILiveFixture.frame($0) }
        frames.forEach(fixture.client.sendAudio)
        let endOfStream = expectation(description: "EOS handed to the transport")
        fixture.socket.fulfillOnEndOfStream(endOfStream)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForFinishWaiters()
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        fixture.becomeReady()
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        await fulfillment(of: [endOfStream], timeout: 2)
        XCTAssertEqual(fixture.socket.binary, frames)
        fixture.socket.completeSend()
        fixture.socket.finalHypothesis("Held words.")
        fixture.socket.peerClose(1_000)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Held words.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testConcurrentAndRepeatedFinishes_shareOneOutcomeAndOneEOS() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.stream([RevAILiveFixture.frame(0)])
        fixture.socket.finalHypothesis("Once.")
        let client = fixture.client
        let first = Task { await client.finishAndWait() }
        let second = Task { await client.finishAndWait() }
        await fixture.waitForFinishWaiters(2)
        XCTAssertEqual(fixture.socket.endOfStreamFrames.count, 1)
        fixture.socket.completeSend()
        fixture.socket.peerClose(1_000)
        let results = [await first.value, await second.value]
        XCTAssertEqual(results, ["Once.", "Once."])
        let repeated = await client.finishAndWait()
        XCTAssertEqual(repeated, "Once.")
        XCTAssertEqual(fixture.socket.endOfStreamFrames.count, 1, "A repeated finish sends nothing more")
        XCTAssertEqual(fixture.factory.sockets.count, 1, "Nothing reconnects")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinalisationBudgetIsTheOneWholeFinishDeadline() {
        let client = RevAILiveClient(accessToken: "synthetic-token", makeConnection: { _ in
            fatalError("Reading the budget must not open a connection")
        })
        XCTAssertEqual(client.finalisationBudget, RevAIStreaming.finishBudget)
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        XCTAssertTrue(client.finishFlushesBufferedAudio)
    }
}

/// Records how deeply a synchronous transport callback re-enters itself.
private final class NestingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var deepest = 0
    var maximum: Int { lock.withLock { deepest } }
    func enter() { lock.withLock { current += 1; deepest = max(deepest, current) } }
    func leave() { lock.withLock { current -= 1 } }
}
